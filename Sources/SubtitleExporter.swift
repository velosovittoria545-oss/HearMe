import Foundation

// MARK: - 字幕生成

/// 把转写行导出成字幕文件。
///
/// 难点：ASR 只给出"这句话是什么时候开始的"，没有结束时间。
/// 所以需要推断每条字幕的时长：
///   1. 优先用真实结束时间（`TranscriptLine.endAt`，由采集层在下一句到达时回填）
///   2. 否则按文字长度估算（中文约 4.5 字/秒，英文约 12 字符/秒）
///   3. 且不能越过下一句的开始时间（否则字幕会重叠）
enum SubtitleExporter {

    enum Format: String, CaseIterable, Identifiable {
        case srt, vtt, ass

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .srt: return "SRT (.srt)"
            case .vtt: return "WebVTT (.vtt)"
            case .ass: return "ASS (.ass)"
            }
        }

        var fileExtension: String { rawValue }
    }

    struct Options {
        var includeSpeaker: Bool = true
        var maxCharsPerLine: Int = 20
        var maxLinesPerCue: Int = 2
        /// 字幕之间留的最小间隔（秒），避免连续字幕首尾相接看起来糊
        var minGap: Double = 0.08
        /// 单条字幕最短时长
        var minDuration: Double = 0.9
        /// 单条字幕最长时长
        var maxDuration: Double = 8.0

        static let `default` = Options()
    }

    // MARK: 对外入口

    /// 生成字幕字符串
    static func render(lines: [TranscriptLine], format: Format, options: Options = .default) -> String {
        let cues = buildCues(from: lines, options: options)
        switch format {
        case .srt: return renderSRT(cues)
        case .vtt: return renderVTT(cues)
        case .ass: return renderASS(cues)
        }
    }

    /// 直接写到文件
    @discardableResult
    static func write(lines: [TranscriptLine], to url: URL, format: Format,
                      options: Options = .default) throws -> Int {
        let text = render(lines: lines, format: format, options: options)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return buildCues(from: lines, options: options).count
    }

    // MARK: 时间轴构建

    struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// 把转写行转换成字幕条目
    static func buildCues(from lines: [TranscriptLine], options: Options) -> [Cue] {
        guard !lines.isEmpty, let origin = lines.first?.at else { return [] }
        let sorted = lines.sorted { $0.at < $1.at }

        // 先算每条的真实起止（相对会话起点）
        var raw: [(start: Double, end: Double, text: String)] = []
        for (i, line) in sorted.enumerated() {
            let start = line.at.timeIntervalSince(origin)
            var end: Double

            if let explicit = line.endAt {
                end = explicit.timeIntervalSince(origin)
            } else {
                end = start + estimateDuration(line.text)
            }

            // 不能越过下一句（留出最小间隔）
            if i + 1 < sorted.count {
                let nextStart = sorted[i + 1].at.timeIntervalSince(origin)
                end = min(end, nextStart - options.minGap)
            }
            // 兜底：至少 minDuration，但不能短到不可读
            if end <= start { end = start + options.minDuration }
            end = min(end, start + options.maxDuration)

            let prefix = options.includeSpeaker ? "\(line.speaker.rawValue)：" : ""
            raw.append((start, max(end, start + 0.3), prefix + line.text))
        }

        // 长句拆成多条字幕（单条不超过 maxCharsPerLine × maxLinesPerCue）
        var cues: [Cue] = []
        let limit = max(8, options.maxCharsPerLine * options.maxLinesPerCue)

        for item in raw {
            // 把说话人前缀单独拆出来，只对正文做切分，避免前缀占字数、也避免重复叠加
            var prefix = ""
            var body = item.text
            if let colon = item.text.firstIndex(of: "：") {
                prefix = String(item.text[...colon])
                body = String(item.text[item.text.index(after: colon)...])
            }

            let pieces = split(body, limit: limit)
            guard pieces.count > 1 else {
                cues.append(Cue(start: item.start, end: item.end, text: wrap(item.text, options: options)))
                continue
            }
            // 按字数比例分配时间，保证语速一致
            let total = Double(pieces.reduce(0) { $0 + $1.count })
            var cursor = item.start
            for (idx, piece) in pieces.enumerated() {
                let share = Double(piece.count) / max(total, 1)
                let span = (item.end - item.start) * share
                let s = cursor
                let e = idx == pieces.count - 1 ? item.end : min(cursor + span, item.end)

                // 拆分后每一片都补回说话人前缀，否则观众不知道是谁在说
                cues.append(Cue(start: s, end: max(e, s + 0.3), text: wrap(prefix + piece, options: options)))
                cursor = e
            }
        }

        // 去重叠
        for i in 0..<max(0, cues.count - 1) {
            if cues[i].end > cues[i + 1].start - 0.05 {
                cues[i].end = max(cues[i].start + 0.3, cues[i + 1].start - options.minGap)
            }
        }
        return cues
    }

    /// 估算一句话的朗读时长
    static func estimateDuration(_ text: String) -> Double {
        let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let other = text.count - cjk
        // 中文 4.5 字/秒；其他字符按 12 字符/秒
        let seconds = Double(cjk) / 4.5 + Double(other) / 12.0
        return max(0.9, min(8.0, seconds + 0.35))
    }

    /// 按标点切分长句，尽量不切在词中间
    static func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }

        var pieces: [String] = []
        var current = ""
        let breakChars: Set<Character> = ["。", "！", "？", "；", "，", "、", ".", "!", "?", ";", ","]

        for ch in text {
            current.append(ch)
            let reachedSoft = current.count >= limit && breakChars.contains(ch)
            // 硬切时，如果正卡在英文单词中间就先别切
            let reachedHard = current.count >= Int(Double(limit) * 1.4)
                && (ch == " " || breakChars.contains(ch) || ch.isCJK)
            if reachedSoft || reachedHard {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current.trimmingCharacters(in: .whitespaces))
        }
        return pieces.filter { !$0.isEmpty }
    }

    /// 按字数折行，但不切断英文单词 / 数字
    static func wrap(_ text: String, options: Options) -> String {
        guard text.count > options.maxCharsPerLine else { return text }

        var out: [String] = []
        var current = ""
        var lineCount = 0
        // 允许在这些字符之后断行
        let softBreaks: Set<Character> = ["，", "、", "。", "；", "：", "！", "？", " ", ",", ".", ";", ":", "!", "?", "）", ")"]

        for ch in text {
            current.append(ch)
            guard current.count >= options.maxCharsPerLine else { continue }
            // 到断点字符才断；否则继续吃字直到遇到空格或标点
            guard softBreaks.contains(ch) || ch == "-" else { continue }
            out.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            lineCount += 1
            if lineCount >= options.maxLinesPerCue { break }
        }

        // 剩下没断完的，说明一直没有标点（比如长英文串），硬切但避免切在字母中间
        if !current.isEmpty, lineCount < options.maxLinesPerCue {
            if current.count > Int(Double(options.maxCharsPerLine) * 1.5) {
                // 找最近的空格
                let head = String(current.prefix(options.maxCharsPerLine))
                if let idx = head.lastIndex(of: " ") {
                    out.append(String(head[..<idx]))
                    current = String(current[head.index(after: idx)...])
                } else {
                    out.append(head)
                    current = String(current.dropFirst(head.count))
                }
            }
            if !current.isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: 渲染

    private static func renderSRT(_ cues: [Cue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(cue.start)) --> \(srtTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    private static func renderVTT(_ cues: [Cue]) -> String {
        var out = "WEBVTT\n\n"
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(vttTime(cue.start)) --> \(vttTime(cue.end))\n"
            out += "\(cue.text)\n\n"
        }
        return out
    }

    private static func renderASS(_ cues: [Cue]) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default, PingFang SC, 64, &H00FFFFFF, &H000000FF, &H00000000, &H80000000, 0, 0, 0, 0, 100, 100, 0, 0, 1, 3, 0, 2, 60, 60, 60, 1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for cue in cues {
            let text = cue.text.replacingOccurrences(of: "\n", with: "\\N")
            out += "Dialogue: 0,\(assTime(cue.start)),\(assTime(cue.end)),Default,,0,0,0,,\(text)\n"
        }
        return out
    }

    // MARK: 时间格式化

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let f = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, f)
    }

    private static func vttTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let f = ms % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, f)
    }

    private static func assTime(_ t: TimeInterval) -> String {
        let cs = Int((t * 100).rounded())
        let h = cs / 360_000
        let m = (cs % 360_000) / 6000
        let s = (cs % 6000) / 100
        let c = cs % 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, c)
    }
}


// MARK: - 保存面板里的格式切换

import AppKit

/// 用 NSSavePanel 的 accessoryView 放一个格式下拉框。
/// NSPopUpButton 需要一个 target/action，这里用单例做桥接。
final class SubtitleExportProxy: NSObject {
    static let shared = SubtitleExportProxy()
    weak var panel: NSSavePanel?
    var selected: SubtitleExporter.Format?

    @objc func formatChanged(_ sender: NSPopUpButton) {
        let all = SubtitleExporter.Format.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        let fmt = all[sender.indexOfSelectedItem]
        selected = fmt
        // 同步改扩展名，避免存成 .srt 但内容是 vtt
        if let panel {
            let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem).\(fmt.fileExtension)"
            panel.allowedContentTypes = [.init(filenameExtension: fmt.fileExtension) ?? .plainText]
        }
    }
}


extension Character {
    /// 是否为中日韩文字（用于判断能否在这里断行）
    var isCJK: Bool {
        guard let s = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(s.value)
            || (0x3400...0x4DBF).contains(s.value)
            || (0x3000...0x303F).contains(s.value)
            || (0xFF00...0xFFEF).contains(s.value)
    }
}

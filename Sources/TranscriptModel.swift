import Foundation
import SwiftUI

// MARK: - 数据结构

struct TranscriptLine: Identifiable, Codable, Hashable {
    let id: UUID
    var at: Date
    var speaker: Speaker
    var text: String
    /// 该行是否为语音识别自动断句产生
    var isFinal: Bool
    /// 真实结束时间：下一句到达时回填，用于生成准确的字幕时间轴
    var endAt: Date?

    init(id: UUID = UUID(), at: Date = Date(), speaker: Speaker, text: String,
         isFinal: Bool = true, endAt: Date? = nil) {
        self.id = id
        self.at = at
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.endAt = endAt
    }
}

enum Speaker: String, Codable, CaseIterable {
    case other = "对方"
    case me = "我"

    var color: Color {
        switch self {
        case .other: return Color(red: 0.30, green: 0.62, blue: 0.98)
        case .me: return Color(red: 0.42, green: 0.80, blue: 0.55)
        }
    }

    var symbol: String {
        switch self {
        case .other: return "person.wave.2.fill"
        case .me: return "mic.fill"
        }
    }
}

// MARK: - 转写存储（按会话落盘）

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var liveText: [Speaker: String] = [:]

    private(set) var sessionURL: URL?
    /// 本次会议的专属文件夹
    private(set) var sessionDirectory: URL?
    private(set) var startedAt: Date?
    private var writeHandle: FileHandle?

    /// 根目录（所有会议文件夹都在这里）
    var outputDirectory: URL {
        // Documents 在 macOS 上受 TCC 保护，用 Application Support 更稳妥
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HearMe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 重新绑定到已有的会话文件（精修、恢复历史时用）
    func bindSession(url: URL, startedAt: Date) {
        sessionURL = url
        sessionDirectory = url.deletingLastPathComponent()
        self.startedAt = startedAt
        try? writeHandle?.close()
        writeHandle = try? FileHandle(forWritingTo: url)
        writeHandle?.seekToEndOfFile()
    }

    func beginSession() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let dir = outputDirectory.appendingPathComponent(f.string(from: Date()), isDirectory: true)
        // 同一分钟重复开始时加序号，避免覆盖
        var finalDir = dir
        var n = 2
        while FileManager.default.fileExists(atPath: finalDir.path) {
            finalDir = dir.deletingLastPathComponent()
                .appendingPathComponent("\(dir.lastPathComponent)-\(n)", isDirectory: true)
            n += 1
        }
        try? FileManager.default.createDirectory(at: finalDir, withIntermediateDirectories: true)

        let url = finalDir.appendingPathComponent("会议.md")
        sessionDirectory = finalDir
        sessionURL = url
        startedAt = Date()
        lines.removeAll()
        liveText.removeAll()

        let header = """
        # 合秘 HearMe 会议转写 · \(Date().formatted(date: .abbreviated, time: .shortened))

        > 由「合秘 HearMe」本地生成（Apple Speech 离线识别，音频不出本机）

        | 时间 | 说话人 | 内容 |
        | --- | --- | --- |
        """ + "\n"
        FileManager.default.createFile(atPath: url.path, contents: header.data(using: .utf8))
        writeHandle = try? FileHandle(forWritingTo: url)
        writeHandle?.seekToEndOfFile()
    }

    func endSession() {
        try? writeHandle?.close()
        writeHandle = nil
    }

    func append(_ line: TranscriptLine) {
        // 新行到达 → 上一行的结束时间就是现在（字幕时间轴需要）
        if var prev = lines.last, prev.endAt == nil {
            prev.endAt = line.at
            lines[lines.count - 1] = prev
        }

        // 与上一行同一说话人、间隔很近、且上一句没说完 → 合并，避免被停顿切碎
        if var last = lines.last,
           last.speaker == line.speaker,
           line.at.timeIntervalSince(last.at) < 3.0,
           last.text.count < 200,
           !endsWithSentencePunctuation(last.text) {
            let sep = needsSpace(last.text, line.text) ? " " : ""
            last.text += sep + line.text
            lines[lines.count - 1] = last
            appendToFile(line: last, isUpdate: true)
            return
        }
        lines.append(line)
        appendToFile(line: line, isUpdate: false)
    }

    private func endsWithSentencePunctuation(_ s: String) -> Bool {
        guard let c = s.last else { return false }
        return "。！？.!?；;".contains(c)
    }

    private func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let la = a.unicodeScalars.last, let fb = b.unicodeScalars.first else { return false }
        // 中日韩之间不加空格
        let cjk = CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}")
        if cjk.contains(la) || cjk.contains(fb) { return false }
        return true
    }

    private func appendToFile(line: TranscriptLine, isUpdate: Bool) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let safe = line.text.replacingOccurrences(of: "|", with: "\\|")
        guard let d = "| \(f.string(from: line.at)) | \(line.speaker.rawValue) | \(safe) |\n".data(using: .utf8) else { return }
        writeHandle?.write(d)
        writeHandle?.synchronizeFile()
        _ = isUpdate
    }

    func updateLive(_ speaker: Speaker, _ text: String) {
        if text.isEmpty { liveText.removeValue(forKey: speaker) }
        else { liveText[speaker] = text }
    }

    /// 用精修结果替换某一路说话人的全部行，再按时间重排
    func replaceAll(speaker: Speaker, with refined: [TranscriptLine]) {
        lines.removeAll { $0.speaker == speaker }
        lines.append(contentsOf: refined)
        lines.sort { $0.at < $1.at }
        rewriteFile()
    }

    /// 整份 Markdown 重写（精修后用）
    private func rewriteFile() {
        guard let url = sessionURL else { return }
        try? writeHandle?.close()
        writeHandle = nil

        var out = """
        # 合秘 HearMe 会议转写 · \(Date().formatted(date: .abbreviated, time: .shortened))

        > 由「合秘 HearMe」本地生成（Apple Speech 离线识别，音频不出本机）

        | 时间 | 说话人 | 内容 |
        | --- | --- | --- |
        """
        out += "\n"
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        for line in lines {
            let safe = line.text.replacingOccurrences(of: "|", with: "\\|")
            out += "| \(f.string(from: line.at)) | \(line.speaker.rawValue) | \(safe) |\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
        writeHandle = try? FileHandle(forWritingTo: url)
        writeHandle?.seekToEndOfFile()
    }

    var plainText: String {
        lines.map { "[\($0.at.formatted(date: .omitted, time: .standard))] \($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
    }

    func export(to url: URL) throws {
        try plainText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 补上最后一行的结束时间（会议停止时调用）
    func finishLastLine(at date: Date) {
        guard var last = lines.last, last.endAt == nil else { return }
        last.endAt = max(date, last.at.addingTimeInterval(0.8))
        lines[lines.count - 1] = last
    }

    // MARK: 字幕文件

    /// 与会议 md 同目录、同名的字幕文件
    func subtitleURL(format: SubtitleExporter.Format) -> URL? {
        guard let dir = sessionDirectory else { return nil }
        return dir.appendingPathComponent("会议.\(format.fileExtension)")
    }

    /// 把当前转写写成字幕文件，返回条目数
    @discardableResult
    func exportSubtitle(format: SubtitleExporter.Format,
                        options: SubtitleExporter.Options = .default) throws -> Int {
        guard let url = subtitleURL(format: format) else { return 0 }
        return try SubtitleExporter.write(lines: lines, to: url, format: format, options: options)
    }

    /// 每次有新行定稿就刷新字幕（会议进行中也能被播放器读到）
    func autoUpdateSubtitles(_ formats: Set<SubtitleExporter.Format>) {
        guard !formats.isEmpty, !lines.isEmpty else { return }
        for f in formats {
            try? exportSubtitle(format: f)
        }
    }
}

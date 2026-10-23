import Foundation
import AVFoundation
import Speech
import SwiftUI
import AppKit

// MARK: - 全局状态

@MainActor
final class AppState: ObservableObject {

    // 配置（持久化）
    @AppStorage("localeCode") var localeCode: String = "zh-CN"
    @AppStorage("captureSystem") var captureSystem: Bool = true
    @AppStorage("captureMic") var captureMic: Bool = false
    @AppStorage("showCaptionPanel") var showCaptionPanel: Bool = false
    @AppStorage("fontSize") var fontSize: Double = 15
    @AppStorage("captionFontSize") var captionFontSize: Double = 19
    /// 每句定稿就自动把最新全文放进剪贴板（随时 ⌘V 就是最新内容）
    @AppStorage("autoCopy") var autoCopy: Bool = false
    @AppStorage("autoCopyScope") var autoCopyScope: String = "latest"  // latest | all

    // 字幕文件
    /// 自动生成哪些格式（逗号分隔，如 "srt,vtt"）
    @AppStorage("subtitleFormats") var subtitleFormatsRaw: String = "srt"
    /// 会议进行中就实时刷新字幕文件
    @AppStorage("subtitleLive") var subtitleLive: Bool = true
    /// 字幕里带上说话人
    @AppStorage("subtitleWithSpeaker") var subtitleWithSpeaker: Bool = true
    /// 单行字数
    @AppStorage("subtitleCharsPerLine") var subtitleCharsPerLine: Int = 20

    var subtitleFormats: Set<SubtitleExporter.Format> {
        get {
            let set = subtitleFormatsRaw.split(separator: ",")
                .compactMap { SubtitleExporter.Format(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
            return set.isEmpty ? [.srt] : Set(set)
        }
        set {
            subtitleFormatsRaw = newValue.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    var subtitleOptions: SubtitleExporter.Options {
        var o = SubtitleExporter.Options.default
        o.includeSpeaker = subtitleWithSpeaker
        o.maxCharsPerLine = max(8, subtitleCharsPerLine)
        return o
    }

    /// 当前会话的字幕文件路径（用于 UI 展示）
    var subtitleFiles: [(format: SubtitleExporter.Format, url: URL)] {
        subtitleFormats.compactMap { f in
            guard let url = store.subtitleURL(format: f) else { return nil }
            return (f, url)
        }.sorted { $0.format.rawValue < $1.format.rawValue }
    }

    // 运行态
    @Published var isRunning = false
    @Published var status: String = "未开始"
    @Published var errorMessage: String?
    @Published var levelOther: Float = 0
    @Published var levelMe: Float = 0
    @Published var permissionState: PermissionState = .unknown

    let store = TranscriptStore()

    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicCapture?
    private var laneOther: SpeechLane?
    private var laneMe: SpeechLane?
    private var wavOther: WavWriter?
    private var wavMe: WavWriter?
    private(set) var wavOtherURL: URL?
    private(set) var wavMeURL: URL?
    private(set) var sessionStart: Date?
    @Published var isRefining = false
    @Published var refineStatus: String = ""
    private var captionWindow: CaptionWindowController?

    enum PermissionState {
        case unknown, needScreen, needSpeech, ready, denied
    }

    // MARK: 初始化

    func bootstrap() {
        refreshPermissions()
        // 首次运行自动发起一次系统授权请求（让「合秘」出现在设置列表里）
        if !SystemAudioCapture.hasPermission(),
           !UserDefaults.standard.bool(forKey: "didAutoRequestScreen") {
            UserDefaults.standard.set(true, forKey: "didAutoRequestScreen")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                _ = SystemAudioCapture.requestPermission()
                self.refreshPermissions()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        let screen = SystemAudioCapture.hasPermission()
        let speech = SFSpeechRecognizer.authorizationStatus()
        if screen && speech == .authorized {
            permissionState = .ready
        } else if !screen && (captureSystem || true) {
            permissionState = .needScreen
        } else if speech != .authorized {
            permissionState = .needSpeech
        } else {
            permissionState = .unknown
        }
    }

    var locale: Locale { Locale(identifier: localeCode) }

    // MARK: 权限申请

    func requestScreenPermission() {
        _ = SystemAudioCapture.requestPermission()
        status = "请在「系统设置 › 隐私与安全性 › 屏幕与系统录音」中勾选「合秘」，然后重新打开本 App"
        openPrivacyPane("ScreenCapture")
        refreshPermissions()
    }

    func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if st != .authorized {
                    self.status = "语音识别被拒绝，请到「隐私与安全性 › 语音识别」开启"
                    self.openPrivacyPane("SpeechRecognition")
                } else {
                    self.status = "语音识别已授权"
                }
                self.refreshPermissions()
            }
        }
    }

    func requestMicPermission() {
        AVAudioApplication.requestRecordPermission { _ in }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 启停

    func toggle() { isRunning ? stop(reason: "手动停止") : start() }

    func start() {
        guard !isRunning else { return }
        errorMessage = nil


        store.beginSession()
        sessionStart = Date()
        if captureSystem, let dir = store.sessionDirectory {
            let url = dir.appendingPathComponent("系统声音.wav")
            wavOtherURL = url
            wavOther = WavWriter(url: url)
        }
        if captureMic, let dir = store.sessionDirectory {
            let url = dir.appendingPathComponent("麦克风.wav")
            wavMeURL = url
            wavMe = WavWriter(url: url)
        }

        // 对方声道
        if captureSystem {
            let lane = SpeechLane(speaker: .other, locale: locale)
            lane.onFinal = { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.append(TranscriptLine(speaker: .other, text: text))
                    self.store.updateLive(.other, "")
                    self.autoCopyIfNeeded(latest: text)
                    self.refreshSubtitlesIfNeeded()
                }
            }
            lane.onPartial = { [weak self] t in
                Task { @MainActor in self?.store.updateLive(.other, t) }
            }
            lane.onLevel = { [weak self] l in
                Task { @MainActor in self?.levelOther = l }
            }
            laneOther = lane
            lane.start()

            let cap = SystemAudioCapture()
            cap.onBuffer = { buf in
                lane.append(buf)
                self.wavOther?.write(buf)
            }
            cap.onError = { [weak self] msg in
                Task { @MainActor in self?.errorMessage = msg }
            }
            systemCapture = cap
            Task {
                do {
                    try await cap.start()
                } catch {
                    DebugLog.write("system capture failed: \(error.localizedDescription)")
                    await MainActor.run {
                        self.errorMessage = "系统声音启动失败：\(error.localizedDescription)"
                        self.status = "采集失败"
                    }
                }
            }
        }

        // 自己声道
        if captureMic {
            let lane = SpeechLane(speaker: .me, locale: locale)
            lane.onFinal = { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.store.append(TranscriptLine(speaker: .me, text: text))
                    self.store.updateLive(.me, "")
                    self.autoCopyIfNeeded(latest: text)
                    self.refreshSubtitlesIfNeeded()
                }
            }
            lane.onPartial = { [weak self] t in
                Task { @MainActor in self?.store.updateLive(.me, t) }
            }
            lane.onLevel = { [weak self] l in
                Task { @MainActor in self?.levelMe = l }
            }
            laneMe = lane
            lane.start()

            let mic = MicCapture()
            mic.onBuffer = { buf in
                lane.append(buf)
                self.wavMe?.write(buf)
            }
            micCapture = mic
            do {
                try mic.start()
            } catch {
                DebugLog.write("mic failed: \(error.localizedDescription)")
                errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            }
        }

        isRunning = true
        status = "转写中 · 全部在本地处理"
        if showCaptionPanel { openCaptionWindow() }
    }

    func stop(reason: String) {
        guard isRunning else { return }
        DebugLog.write("stop() reason=\(reason) lines=\(store.lines.count)")
        systemCapture?.stop()
        systemCapture = nil
        micCapture?.stop()
        micCapture = nil
        // 让识别器把最后一句吐完（最多 2 秒），再收尾
        let group = DispatchGroup()
        if let l = laneOther { group.enter(); l.stop { group.leave() } }
        if let l = laneMe { group.enter(); l.stop { group.leave() } }
        laneOther = nil
        laneMe = nil
        wavOther?.close()
        wavMe?.close()
        wavOther = nil
        wavMe = nil
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.store.endSession()
            // 收尾：把最后一行的结束时间补上，再生成一次字幕
            self.finalizeSubtitles()
            self.status = "已停止（\(reason)）· \(self.store.lines.count) 句"
        }
        isRunning = false
        levelOther = 0
        levelMe = 0
    }

    // MARK: 字幕

    /// 会议结束时最终生成，并补全最后一行的结束时间
    func finalizeSubtitles() {
        guard !store.lines.isEmpty else { return }
        store.finishLastLine(at: Date())
        store.autoUpdateSubtitles(subtitleFormats)
        let names = subtitleFormats.map(\.fileExtension).sorted().joined(separator: " / ")
        DebugLog.write("subtitles written: \(names)")
    }

    /// 手动导出字幕（选格式 + 位置）
    func exportSubtitleInteractive() {
        guard !store.lines.isEmpty else {
            errorMessage = "还没有可导出的转写内容"
            return
        }
        let panel = NSSavePanel()
        let formats = subtitleFormats
        let defaultFormat = formats.contains(.srt) ? SubtitleExporter.Format.srt : (formats.first ?? .srt)
        panel.nameFieldStringValue = "会议字幕.\(defaultFormat.fileExtension)"
        panel.allowedContentTypes = [.init(filenameExtension: defaultFormat.fileExtension) ?? .plainText]
        panel.canCreateDirectories = true

        // 允许在保存面板里改格式
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
        picker.addItems(withTitles: SubtitleExporter.Format.allCases.map(\.displayName))
        picker.selectItem(at: SubtitleExporter.Format.allCases.firstIndex(of: defaultFormat) ?? 0)
        picker.target = SubtitleExportProxy.shared
        picker.action = #selector(SubtitleExportProxy.formatChanged(_:))
        SubtitleExportProxy.shared.panel = panel
        panel.accessoryView = picker

        if panel.runModal() == .OK, let url = panel.url {
            let fmt = SubtitleExportProxy.shared.selected ?? defaultFormat
            do {
                let n = try SubtitleExporter.write(lines: store.lines, to: url,
                                                   format: fmt, options: subtitleOptions)
                status = "已导出 \(n) 条字幕（\(fmt.rawValue.uppercased())）"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "字幕导出失败：\(error.localizedDescription)"
            }
        }
    }

    /// 重新生成当前会话的字幕文件
    func regenerateSubtitles() {
        guard !store.lines.isEmpty else { return }
        do {
            var total = 0
            for f in subtitleFormats {
                total = try store.exportSubtitle(format: f, options: subtitleOptions)
            }
            status = "字幕已更新 · \(total) 条"
        } catch {
            errorMessage = "字幕生成失败：\(error.localizedDescription)"
        }
    }

    // MARK: 字号

    /// 正文字号范围。下限 11 保证可读，上限 40 够大字模式
    static let fontSizeRange: ClosedRange<Double> = 11...40
    static let captionFontSizeRange: ClosedRange<Double> = 12...48

    func adjustFontSize(_ delta: Double) {
        let next = (fontSize + delta).clamped(to: Self.fontSizeRange)
        guard next != fontSize else { return }
        fontSize = next
        status = "正文字号 \(Int(next))"
    }

    func resetFontSize() {
        fontSize = 15
        status = "正文字号已重置"
    }

    /// 浮窗字号单独调（浮窗在会议时可能离得远，需要更大）
    func adjustCaptionFontSize(_ delta: Double) {
        let next = (captionFontSize + delta).clamped(to: Self.captionFontSizeRange)
        guard next != captionFontSize else { return }
        captionFontSize = next
        status = "字幕字号 \(Int(next))"
    }

    // MARK: 剪贴板

    /// 自动复制：默认关。开了之后每句定稿就写剪贴板，
    /// 这样随时 ⌘V 都能粘出最新内容，不用切窗口去点。
    /// 实时刷新字幕文件（会议中就能被播放器读到）
    private func refreshSubtitlesIfNeeded() {
        guard subtitleLive, !store.lines.isEmpty else { return }
        store.autoUpdateSubtitles(subtitleFormats)
    }

    private func autoCopyIfNeeded(latest: String) {
        guard autoCopy else { return }
        let text = autoCopyScope == "all" ? store.plainText : latest
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 手动复制最新一句
    func copyLatest() {
        guard let last = store.lines.last?.text else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(last, forType: .string)
    }

    /// 复制全文
    func copyAll() {
        let text = store.plainText
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: Whisper 精修

    /// 用本地 Whisper 重新转写这次会议的录音，替换掉实时识别的粗略结果。
    /// 一次会议只跑一次，2 分钟音频约 3 秒。
    func refineWithWhisper() {
        guard !isRefining else { return }
        guard let start = sessionStart else {
            errorMessage = "还没有可精修的会议记录"
            return
        }

        let cfg = WhisperRefiner.Config.detect()
        if let problem = WhisperRefiner.checkEnvironment(cfg) {
            DebugLog.write("refine env problem: \(problem)")
            errorMessage = problem
            return
        }

        let jobs: [(URL, Speaker)] = [
            (wavOtherURL, .other),
            (wavMeURL, .me)
        ].compactMap { url, sp in
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (url, sp)
        }
        guard !jobs.isEmpty else {
            errorMessage = "找不到这次会议的录音文件"
            return
        }

        isRefining = true
        refineStatus = "正在精修…"

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var total = 0
            var failures: [String] = []
            for (url, speaker) in jobs {
                do {
                    let n = try await MainActor.run {
                        try self.store.replaceLines(
                            from: url, speaker: speaker,
                            sessionStart: start, config: cfg
                        )
                    }
                    total += n
                } catch {
                    DebugLog.write("refine failed \(speaker.rawValue): \(error.localizedDescription)")
                    failures.append("\(speaker.rawValue): \(error.localizedDescription)")
                }
            }

            let finalTotal = total
            let finalFailures = failures
            await MainActor.run {
                self.isRefining = false
                if finalFailures.isEmpty {
                    self.refineStatus = "精修完成 · \(finalTotal) 句"
                    self.status = "精修完成（Whisper）· \(finalTotal) 句"
                } else {
                    self.refineStatus = "精修部分失败"
                    self.errorMessage = finalFailures.joined(separator: "\n")
                }
            }
        }
    }

    /// 环境是否就绪（用于 UI 灰显按钮）
    var whisperAvailable: Bool {
        WhisperRefiner.checkEnvironment(.detect()) == nil
    }

    // MARK: 字幕浮窗

    func toggleCaption() {
        showCaptionPanel.toggle()
        showCaptionPanel ? openCaptionWindow() : closeCaptionWindow()
    }

    private func openCaptionWindow() {
        if captionWindow == nil {
            captionWindow = CaptionWindowController(store: store)
        }
        captionWindow?.showWindow(nil)
        captionWindow?.window?.orderFrontRegardless()
    }

    private func closeCaptionWindow() {
        captionWindow?.close()
        captionWindow = nil
    }

    // MARK: 导出

    func exportInteractive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "会议转写.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? store.export(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func openOutputFolder() {
        NSWorkspace.shared.open(store.sessionDirectory ?? store.outputDirectory)
    }

    /// 打开根目录，看所有会议
    func openRootFolder() {
        NSWorkspace.shared.open(store.outputDirectory)
    }

    /// 历史会议列表（按时间倒序）
    var sessionFolders: [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: store.outputDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
        return all
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}

extension Double {
    /// 把数值夹在闭区间内
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

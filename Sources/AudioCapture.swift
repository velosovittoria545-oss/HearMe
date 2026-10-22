import AVFoundation
import Speech
import ScreenCaptureKit
import CoreMedia
import Foundation

// MARK: - 单路语音识别

/// 一条独立的识别通道：接收 PCM 缓冲，输出断句后的文本。
/// 语音识别有单段时长上限，这里按"静音"与"最长 50 秒"两个条件轮换分段。
final class SpeechLane: NSObject, SFSpeechRecognizerDelegate {

    let speaker: Speaker
    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var segmentStartedAt = Date()
    private var quietSince: Date?
    private var pendingText = ""
    private var lastEmitted = ""
    private var restarting = false
    private var stopping = false
    private var stopCompletion: (() -> Void)?

    /// 最终断句文本
    var onFinal: ((String) -> Void)?
    /// 实时草稿（用于 UI 上浅色显示）
    var onPartial: ((String) -> Void)?
    /// 音量 0...1
    var onLevel: ((Float) -> Void)?

    private let maxSegment: TimeInterval = 45
    private let silenceGap: TimeInterval = 1.5
    /// 自适应静音阈值：低于"近期峰值"的这个比例就算安静
    private let silenceRatio: Float = 0.16
    /// 绝对下限，防止把持续低语判成静音
    private let silenceFloor: Float = 0.02
    private var peak: Float = 0.05
    private var peakAt = Date()

    init(speaker: Speaker, locale: Locale) {
        self.speaker = speaker
        self.recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))!
        super.init()
        self.recognizer.delegate = self
    }

    var isAvailable: Bool { recognizer.isAvailable }

    // MARK: 生命周期

    func start() {
        guard !restarting else { return }
        beginSegment()
    }

    private func beginSegment() {
        task?.cancel()
        task = nil
        pendingText = ""
        lastEmitted = ""
        segmentStartedAt = Date()
        quietSince = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        // 领域词提示，能显著改善专有名词识别
        req.contextualStrings = Self.domainVocabulary
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // 离线，音频不出本机
        }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let r = result {
                let text = r.bestTranscription.formattedString
                self.pendingText = text
                self.onPartial?(text)
                if r.isFinal {
                    self.flushSegment(reason: "final")
                    if self.stopping {
                        self.stopping = false
                        self.stopCompletion?()
                        self.stopCompletion = nil
                    }
                }
            }
            if let e = error as NSError? {
                if e.code == 1101 || e.code == 216 { return }  // 主动取消 / 正常结束
                self.scheduleRestart(reason: "error \(e.code)")
            }
        }
    }

    private func scheduleRestart(reason: String) {
        guard !restarting else { return }
        restarting = true
        flushSegment(reason: reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restarting = false
            self?.beginSegment()
        }
    }

    private func flushSegment(reason: String) {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != lastEmitted {
            lastEmitted = text
            onFinal?(text)
        }
        pendingText = ""
        onPartial?("")
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    /// 停止：endAudio 后等识别器吐出最终结果，最多等 2 秒，兜底把草稿也发出去
    func stop(completion: (() -> Void)? = nil) {
        stopping = true
        stopCompletion = completion
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // 兜底：如果 isFinal 没来，把草稿发出去
            let text = self.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != self.lastEmitted {
                self.lastEmitted = text
                self.onFinal?(text)
            }
            self.pendingText = ""
            self.onPartial?("")
            self.request = nil
            self.task?.cancel()
            self.task = nil
            self.stopping = false
            self.stopCompletion?()
            self.stopCompletion = nil
        }
    }

    // MARK: 音频入口

    /// 领域词表：显著改善专有名词与中英混说的识别率
    static let domainVocabulary: [String] = [
        "架构师", "架构设计", "智能体", "大模型", "知识库", "知识平台", "向量库", "向量检索",
        "微服务", "消息队列", "网关", "中间件", "云原生", "可观测", "灰度", "回滚", "熔断", "降级",
        "模型接入", "推理", "微调", "算力", "评测", "召回", "重排", "切块", "幻觉", "护栏",
        "数据中台", "数据平台", "主数据", "元数据", "数据湖", "数仓", "血缘",
        "研发效能", "上线准入", "技术选型", "建设规范", "平台化", "中台",
        "RAG", "Agent", "Agents", "MCP", "MLOps", "AgentOps", "DevOps", "DevSecOps",
        "Guardrails", "Prompt", "Embedding", "Token", "SLA", "QPS", "API", "SDK", "CI", "CD",
        "LangGraph", "LangChain", "vLLM", "Milvus", "Elasticsearch", "Kubernetes",
        "Claude", "OpenAI", "GPT", "DeepSeek", "Qwen", "Codex", "Cursor", "n8n",
        "锐捷", "网络设备", "交换机", "固件", "供应链", "制造",
        // AI 被听成"阿姨"是最常见的错，这几个词能拉回来
        "AI", "AI平台", "AI安全", "人工智能", "AI应用", "AI中台",
        "合秘", "HearMe", "会议", "转写", "字幕"
    ]

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let req = request, !stopping else { return }
        let now = Date()
        let level = Self.rms(buffer)
        onLevel?(level)

        // 峰值缓慢衰减，跟随说话人音量
        if level > peak { peak = level; peakAt = now }
        else if now.timeIntervalSince(peakAt) > 6 { peak = max(peak * 0.92, silenceFloor) }

        // 长段轮换（Apple 识别单段有上限）
        if now.timeIntervalSince(segmentStartedAt) > maxSegment {
            scheduleRestart(reason: "rotate")
            return
        }

        let threshold = max(peak * silenceRatio, silenceFloor)
        if level < threshold {
            if quietSince == nil { quietSince = now }
            if let q = quietSince, now.timeIntervalSince(q) > silenceGap, !pendingText.isEmpty {
                DebugLog.write("[\(speaker.rawValue)] silence break \(String(format: "%.1f", now.timeIntervalSince(q)))s: \(pendingText)")
                scheduleRestart(reason: "silence")
                return
            }
        } else {
            quietSince = nil
        }

        req.append(buffer)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        var i = 0
        while i < n { sum += ch[i] * ch[i]; i += 4 }
        let count = Float((n + 3) / 4)
        return min(1, sqrt(sum / max(count, 1)) * 12)
    }

    func speechRecognizer(_ r: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available { start() }
    }
}

// MARK: - 采样格式转换

/// 把任意输入格式统一转成 16k 单声道 float，喂给识别器与 WAV。
final class Mono16kConverter {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if sourceFormat == nil || sourceFormat != input.format {
            sourceFormat = input.format
            converter = AVAudioConverter(from: input.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if err != nil || out.frameLength == 0 { return nil }
        return out
    }
}

// MARK: - WAV 落盘

final class WavWriter {
    private var file: AVAudioFile?
    private let url: URL
    private(set) var framesWritten: AVAudioFramePosition = 0

    init?(url: URL) {
        self.url = url
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let f = try? AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        file = f
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            DebugLog.write("wav write failed: \(error.localizedDescription)")
        }
    }

    /// 关键：必须让 AVAudioFile 析构，它才会把 WAV 头的 data chunk size 回填。
    /// 之前这里是空实现，导致文件有 3MB 数据但头里写着 0 帧，标准读取器全读不到。
    func close() {
        guard let file else { return }
        _ = file.length          // 触发一次同步
        self.file = nil          // 释放即落盘
        // 兜底：如果头里帧数还是 0，手工修正
        fixHeaderIfNeeded()
    }

    private func fixHeaderIfNeeded() {
        guard let h = try? FileHandle(forUpdating: url) else { return }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 44), head.count == 44 else { return }

        // RIFF size 在 4..8，data chunk size 在 40..44
        let dataSize = head.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
        if dataSize != 0 { return }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let pcmBytes = UInt32(max(0, (fileSize ?? 0) - 44))
        guard pcmBytes > 0 else { return }

        var riff = UInt32(36) + pcmBytes
        var data = pcmBytes
        do {
            try h.seek(toOffset: 4)
            try h.write(contentsOf: Data(bytes: &riff, count: 4))
            try h.seek(toOffset: 40)
            try h.write(contentsOf: Data(bytes: &data, count: 4))
        } catch {
            DebugLog.write("wav header fix failed: \(error.localizedDescription)")
        }
        DebugLog.write("wav header fixed: \(pcmBytes) bytes")
    }
}

// MARK: - 系统声音采集（会议对方）

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "hearme.system.audio", qos: .userInitiated)
    private let converter = Mono16kConverter()

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "HearMe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可采集的显示器"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true   // 不录自己 App 的声音
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        // 只要音频，把视频压到最小以降低开销
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 6

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        let s = stream
        stream = nil
        s?.stopCapture(completionHandler: { _ in })
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else { return }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        guard let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        if let mono = converter.convert(pcm) { onBuffer?(mono) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("系统声音采集中断：\(error.localizedDescription)")
    }
}

// MARK: - 麦克风采集（我）

final class MicCapture {
    private let engine = AVAudioEngine()
    private let converter = Mono16kConverter()
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "HearMe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风不可用（可能未授权）"])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self else { return }
            if let mono = self.converter.convert(buf) { self.onBuffer?(mono) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

import Foundation
import AVFoundation

// MARK: - 本地 Whisper 精修

/// 会议结束后，用本地 Whisper 把已录下的 WAV 重新转一遍，替换掉 Apple ASR 的粗略结果。
///
/// 为什么需要这一步：
/// Apple 的设备端 ASR 追求低延迟，对中英混说（"RAG 召回"、"Agent 编排"）和专业术语
/// 错误率明显偏高。Whisper large-v3-turbo 在这类内容上准得多，但它不适合实时。
/// 所以做成两段式：实时用 Apple 保时效，散会后用 Whisper 保准确。
///
/// 音频从哪来：`WavWriter` 已经把两路音频落成 16kHz 单声道 WAV，
/// 这里只负责调 `Scripts/refine.py`，不碰音频本身。
enum WhisperRefiner {

    struct Config {
        var pythonPath: String
        var scriptPath: String
        var modelPath: String
        var language: String
        var prompt: String

        static let defaultPrompt = "会议讨论内容涉及：RAG、Agent、MCP、MLOps、向量检索、模型接入、技术选型、上线准入、知识平台、微服务、消息队列、数据中台、灰度、回滚。"

        /// 自动探测可用环境
        static func detect() -> Config {
            let fm = FileManager.default
            let base = Bundle.main.bundleURL.deletingLastPathComponent()

            // venv 优先（DSH 运行时的 python 有签名限制，装不了 mlx）
            let pythons = [
                base.appendingPathComponent(".venv/bin/python").path,
                base.appendingPathComponent("../.venv/bin/python").path,
                "\(NSHomeDirectory())/.venv/bin/python",
                "/opt/homebrew/bin/python3",
                "/usr/bin/python3"
            ]
            let python = pythons.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"

            let scripts = [
                base.appendingPathComponent("Scripts/refine.py").path,
                base.appendingPathComponent("Contents/Resources/Scripts/refine.py").path,
                base.appendingPathComponent("../Scripts/refine.py").path
            ]
            let script = scripts.first { fm.fileExists(atPath: $0) }
                ?? base.appendingPathComponent("Scripts/refine.py").path

            return Config(
                pythonPath: python,
                scriptPath: script,
                modelPath: resolveModelPath(),
                language: "zh",
                prompt: defaultPrompt
            )
        }

        /// 模型路径查找顺序：
        ///   1. 环境变量 HEARME_WHISPER_MODEL
        ///   2. 用户默认设置（App 内可改）
        ///   3. 常见位置（LM Studio / HuggingFace 缓存）
        static func resolveModelPath() -> String {
            if let env = ProcessInfo.processInfo.environment["HEARME_WHISPER_MODEL"],
               !env.isEmpty, FileManager.default.fileExists(atPath: env) {
                return env
            }
            if let saved = UserDefaults.standard.string(forKey: "whisperModelPath"),
               !saved.isEmpty, FileManager.default.fileExists(atPath: saved) {
                return saved
            }
            let home = NSHomeDirectory()
            let candidates = [
                "\(home)/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots",
                "\(home)/.lmstudio/models/mlx-community/whisper-large-v3-turbo",
                "/Volumes/MacData/dev/LMStudio/llm/mlx-community/whisper-large-v3-turbo",
                "\(home)/Library/Application Support/HearMe/whisper-large-v3-turbo"
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c) {
                return c
            }
            // 都没找到：返回第一个候选，让 checkEnvironment 报出明确错误
            return candidates[0]
        }
    }

    struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Result: Decodable {
        let segments: [Segment]
        let language: String?
    }

    enum RefineError: LocalizedError {
        case pythonMissing(String)
        case scriptMissing(String)
        case modelMissing(String)
        case mlxMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let p): return "找不到 Python：\(p)"
            case .scriptMissing(let p): return "找不到 refine.py：\(p)"
            case .modelMissing(let p): return "找不到 Whisper 模型：\(p)"
            case .mlxMissing: return "当前 Python 未安装 mlx-whisper"
            case .failed(let m): return "Whisper 转写失败：\(m)"
            }
        }
    }

    /// 环境自检，返回 nil 表示就绪
    static func checkEnvironment(_ cfg: Config) -> String? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: cfg.pythonPath) else {
            return RefineError.pythonMissing(cfg.pythonPath).localizedDescription
        }
        guard fm.fileExists(atPath: cfg.scriptPath) else {
            return RefineError.scriptMissing(cfg.scriptPath).localizedDescription
        }
        guard fm.fileExists(atPath: cfg.modelPath) else {
            return RefineError.modelMissing(cfg.modelPath).localizedDescription
        }
        let probe = run(cfg.pythonPath, ["-c", "import mlx_whisper, numpy; print('ok')"], timeout: 60)
        if !probe.output.contains("ok") {
            return RefineError.mlxMissing.localizedDescription
        }
        return nil
    }

    /// 转写单个 WAV
    static func transcribe(wav: URL, config cfg: Config) throws -> [Segment] {
        var args = [cfg.scriptPath, wav.path, cfg.modelPath, cfg.language]
        if !cfg.prompt.isEmpty { args.append(cfg.prompt) }

        let r = run(cfg.pythonPath, args, timeout: 3600)
        guard r.status == 0 else {
            let msg = r.error.isEmpty ? r.output : r.error
            throw RefineError.failed(String(msg.suffix(400)))
        }
        guard let line = r.output
            .split(separator: "\n")
            .last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let data = String(line).data(using: .utf8),
              let result = try? JSONDecoder().decode(Result.self, from: data)
        else {
            throw RefineError.failed("无法解析输出：\(r.output.suffix(300))")
        }
        return result.segments
    }

    // MARK: 进程调用

    struct RunResult {
        var status: Int32
        var output: String
        var error: String
    }

    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"        // 只认本地模型，不联网
        env["TRANSFORMERS_OFFLINE"] = "1"
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do { try p.run() } catch {
            return RunResult(status: -1, output: "", error: error.localizedDescription)
        }

        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        return RunResult(
            status: p.terminationStatus,
            output: String(data: outData, encoding: .utf8) ?? "",
            error: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - 合并回转写

extension TranscriptStore {

    /// 用 Whisper 结果替换某一路说话人的全部行
    @discardableResult
    func replaceLines(from wav: URL, speaker: Speaker, sessionStart: Date,
                      config: WhisperRefiner.Config) throws -> Int {
        let segments = try WhisperRefiner.transcribe(wav: wav, config: config)
        guard !segments.isEmpty else { return 0 }

        let refined: [TranscriptLine] = segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(
                at: sessionStart.addingTimeInterval(seg.start),
                speaker: speaker,
                text: text
            )
        }
        guard !refined.isEmpty else { return 0 }

        replaceAll(speaker: speaker, with: refined)
        return refined.count
    }
}

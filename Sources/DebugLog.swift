import Foundation

/// 轻量调试日志：默认关闭，设置环境变量 HEARME_DEBUG=1 后写入 /tmp/hearme-debug.log
enum DebugLog {
    static let url = URL(fileURLWithPath: "/tmp/hearme-debug.log")
    private static let enabled = ProcessInfo.processInfo.environment["HEARME_DEBUG"] == "1"

    static func write(_ s: String) {
        guard enabled else { return }
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

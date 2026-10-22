import Foundation
import AVFoundation
import Speech
import CoreGraphics

// MARK: - 诊断入口

/// 这些命令用于排查权限与环境问题，不参与正常使用。
enum SelfTest {

    /// 打印当前权限状态
    static func printPermissions() -> Int32 {
        print("屏幕与系统录音: \(CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")")
        print("麦克风: \(AVAudioApplication.shared.recordPermission == .granted ? "已授权" : "未授权")")
        let st = SFSpeechRecognizer.authorizationStatus()
        let names: [SFSpeechRecognizerAuthorizationStatus: String] = [
            .notDetermined: "未询问", .denied: "被拒绝", .restricted: "受限", .authorized: "已授权"
        ]
        print("语音识别: \(names[st] ?? "未知")")
        for code in ["zh-CN", "en-US"] {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: code)) {
                print("  \(code): 可用=\(r.isAvailable) 离线=\(r.supportsOnDeviceRecognition)")
            }
        }
        return 0
    }
}

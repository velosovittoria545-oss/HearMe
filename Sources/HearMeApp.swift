import SwiftUI
import AppKit

// 命令行入口：--perm-status 打印权限状态；否则正常启动 App
@main
struct Launcher {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--perm-status") {
            exit(SelfTest.printPermissions())
        }
        HearMeApp.main()
    }
}

struct HearMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("合秘 HearMe · 会议实时字幕", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 780, minHeight: 560)
                .onAppear {
                    appDelegate.state = state
                    state.bootstrap()
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // 放进系统「显示」菜单，和 macOS 其他 App 的习惯一致
            CommandGroup(after: .sidebar) {
                Divider()
                Button("放大字号") { state.adjustFontSize(1) }
                    .keyboardShortcut("=", modifiers: [.command])
                Button("缩小字号") { state.adjustFontSize(-1) }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("实际大小") { state.resetFontSize() }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
                Button("字幕放大") { state.adjustCaptionFontSize(1) }
                    .keyboardShortcut("=", modifiers: [.command, .shift])
                Button("字幕缩小") { state.adjustCaptionFontSize(-1) }
                    .keyboardShortcut("-", modifiers: [.command, .shift])
            }
            CommandMenu("转写") {
                Button("开始 / 停止") { state.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("显示 / 隐藏字幕浮窗") { state.toggleCaption() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Whisper 精修本次会议") { state.refineWithWhisper() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("导出字幕…") { state.exportSubtitleInteractive() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("导出文本…") { state.exportInteractive() }
                    .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        installSignalHandlers()
        // --autostart：启动即开始转写（配合登录项使用）
        if CommandLine.arguments.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.state?.start()
            }
        }
    }


    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        state?.stop(reason: "应用退出")
    }

    /// 被 SIGTERM / SIGINT 杀掉时也要走一遍 stop，否则 WAV 头不会回填、最后一句会丢
    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.state?.stop(reason: "收到退出信号")
                }
                // 给 stop 的异步收尾留点时间，再退出
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    NSApp.terminate(nil)
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }
}

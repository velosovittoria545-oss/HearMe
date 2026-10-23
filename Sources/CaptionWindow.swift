import AppKit
import SwiftUI

// MARK: - 悬浮字幕窗口

/// 无边框、可拖动、始终置顶的字幕浮窗。
/// 文字可选中复制（⌘C），拖动只能拖标题条区域，避免与选字冲突。
final class CaptionWindowController: NSWindowController {

    private let store: TranscriptStore
    private var hosting: NSHostingView<CaptionView>!

    init(store: TranscriptStore) {
        self.store = store

        let win = CaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 160),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        // 关键：不再整窗拖动，否则在文字上拖动会变成移动窗口、无法选字
        win.isMovableByWindowBackground = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: win)

        hosting = NSHostingView(rootView: CaptionView(store: store))
        win.contentView = hosting

        // 恢复上次位置，但必须满足两个条件：
        //   1. 那块区域还在某个屏幕上（换显示器后旧坐标可能完全落到屏幕外）
        //   2. 它在鼠标当前所在的屏幕上（多屏时不要把浮窗丢到另一块屏）
        let mouse = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main

        if let saved = UserDefaults.standard.string(forKey: "captionFrame") {
            let r = NSRectFromString(saved)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(r) }
            let onActive = activeScreen?.visibleFrame.intersects(r) ?? false
            if r.width > 200, r.height > 60, onScreen, onActive {
                win.setFrame(r, display: false)
            } else {
                positionAtBottom(on: activeScreen)
            }
        } else {
            positionAtBottom(on: activeScreen)
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: win, queue: .main
        ) { note in
            guard let w = note.object as? NSWindow else { return }
            UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: "captionFrame")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func positionAtBottom(on screen: NSScreen? = nil) {
        guard let win = window else { return }
        let target = screen
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let f = target?.visibleFrame else { return }

        // 尺寸也限制在该屏内，避免超出
        var size = win.frame.size
        size.width = min(size.width, f.width - 40)
        size.height = min(size.height, f.height - 40)

        win.setFrame(NSRect(
            x: f.midX - size.width / 2,
            y: f.minY + 8,
            width: size.width,
            height: size.height
        ), display: false)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.orderFrontRegardless()
    }
}

/// 需要能成为 key window，否则文字选不中、⌘C 也收不到。
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 字幕内容

struct CaptionView: View {
    @ObservedObject var store: TranscriptStore
    @AppStorage("captionLines") private var captionLines: Int = 2
    @AppStorage("captionFontSize") private var captionFontSize: Double = 19
    @AppStorage("captionOpacity") private var captionOpacity: Double = 0.88
    @State private var clickThrough = false
    @State private var justCopied = false

    private var recent: [TranscriptLine] {
        Array(store.lines.suffix(captionLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            captionBody
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(captionOpacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .padding(1)
    }

    // MARK: 顶栏（也是拖动区）

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.liveText.isEmpty ? Color.gray.opacity(0.5) : Color.green)
                .frame(width: 6, height: 6)
            Text("实时字幕")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text("可随时选中复制")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.32))

            Spacer()

            // 复制
            Button {
                copyVisible()
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(justCopied ? .green : .white.opacity(0.55))
            .help("复制当前字幕（⇧⌘C）")
            .keyboardShortcut("c", modifiers: [.command, .shift])

            // 复制最新一句
            Button {
                copyLatest()
            } label: {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help("只复制最新一句")

            // 鼠标穿透
            Button {
                clickThrough.toggle()
                applyClickThrough()
            } label: {
                Image(systemName: clickThrough ? "cursorarrow.slash" : "cursorarrow")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.55))
            .help(clickThrough ? "恢复可点击（现在鼠标可穿透）" : "鼠标穿透，不挡会议操作")

            Menu {
                Picker("显示行数", selection: $captionLines) {
                    Text("1 行").tag(1); Text("2 行").tag(2); Text("3 行").tag(3); Text("5 行").tag(5)
                }
                Menu("字号：\(Int(captionFontSize))") {
                    Button("放大 (+1)") {
                        captionFontSize = min(captionFontSize + 1, 48)
                    }
                    Button("缩小 (-1)") {
                        captionFontSize = max(captionFontSize - 1, 12)
                    }
                    Divider()
                    ForEach([14.0, 16.0, 19.0, 23.0, 28.0, 34.0, 40.0], id: \.self) { v in
                        Button("\(Int(v)) pt") { captionFontSize = v }
                    }
                }
                Slider(value: $captionOpacity, in: 0.3...1.0) { Text("背景不透明度") }
                Divider()
                Button("复制全部转写") { copyAll() }
                Button("导出为文本…") { exportAll() }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.white.opacity(0.55))
        }
        .background(DragHandle())
    }

    // MARK: 字幕正文

    private var captionBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            if recent.isEmpty, let live = store.liveText[.other] {
                Text(live)
                    .font(.system(size: captionFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(captionLines)
                    .textSelection(.enabled)
            } else if recent.isEmpty {
                Text("等待对方说话…")
                    .font(.system(size: captionFontSize))
                    .foregroundStyle(.white.opacity(0.35))
            }

            ForEach(recent) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.speaker.rawValue)
                        .font(.system(size: captionFontSize * 0.62, weight: .bold))
                        .foregroundStyle(line.speaker.color)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                    Text(line.text)
                        .font(.system(size: captionFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            if let live = store.liveText[.other], !live.isEmpty, !recent.isEmpty {
                Text(live)
                    .font(.system(size: captionFontSize))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        // 双击字幕区任意位置也能全选
        .textSelection(.enabled)
    }

    // MARK: 动作

    private func copyVisible() {
        let text = recent.isEmpty
            ? (store.liveText[.other] ?? "")
            : recent.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashCopied()
    }

    private func copyLatest() {
        guard let last = recent.last?.text ?? store.liveText[.other], !last.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(last, forType: .string)
        flashCopied()
    }

    private func copyAll() {
        let text = store.plainText
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashCopied()
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "会议转写.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? store.export(to: url)
        }
    }

    private func flashCopied() {
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
    }

    private func applyClickThrough() {
        guard let win = window else { return }
        win.ignoresMouseEvents = clickThrough
    }

    private var window: NSWindow? {
        NSApp.windows.first { $0 is CaptionPanel && $0.isVisible }
    }
}

// MARK: - 只拖标题条的拖动区

/// 顶栏放一层透明 NSView，只在这里按下拖动才移动窗口；
/// 正文区域的拖动留给文字选择，两者不打架。
private struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

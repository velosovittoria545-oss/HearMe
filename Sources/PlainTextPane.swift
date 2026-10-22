import SwiftUI
import AppKit

// MARK: - 纯文本转写面板

/// 用 NSTextView 承载全文，解决 SwiftUI 列表的两个硬伤：
///   1. `LazyVStack` + 实时追加会让已选中的文字失效
///   2. 自动滚动会打断拖选
///
/// NSTextView 在内容追加时能**保住选区**，这是"随时可复制"的关键。
struct PlainTextPane: NSViewRepresentable {

    let lines: [TranscriptLine]
    let liveText: [Speaker: String]
    let fontSize: Double
    let isRunning: Bool
    /// 内容变化时是否跟随滚动（用户正在选择时会自动关掉）
    @Binding var autoScroll: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.isRichText = false
        tv.usesFindBar = true            // ⌘F 可搜索
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.allowsUndo = false

        context.coordinator.textView = tv
        context.coordinator.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.render(
            lines: lines,
            liveText: liveText,
            fontSize: fontSize,
            isRunning: isRunning,
            autoScroll: autoScroll
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?

        private var lastRendered = ""
        private var userIsSelecting = false

        func render(lines: [TranscriptLine], liveText: [Speaker: String],
                    fontSize: Double, isRunning: Bool, autoScroll: Bool) {
            guard let tv = textView else { return }

            let attr = build(lines: lines, liveText: liveText, fontSize: fontSize)
            let newText = attr.string
            guard newText != lastRendered else {
                // 文字没变，但字号可能变了
                if abs((tv.font?.pointSize ?? 0) - fontSize) > 0.5 {
                    tv.textStorage?.setAttributedString(attr)
                }
                return
            }

            // 关键：记录并恢复选区，让用户选中的文字在实时追加时不被清掉
            let savedRange = tv.selectedRange()
            let hadSelection = savedRange.length > 0
            let wasAtBottom = isScrolledToBottom()

            tv.textStorage?.setAttributedString(attr)
            lastRendered = newText

            if hadSelection, savedRange.location + savedRange.length <= newText.utf16.count {
                tv.setSelectedRange(savedRange)
            } else if savedRange.location <= newText.utf16.count {
                // 光标位置保留（没选中时）
                tv.setSelectedRange(NSRange(location: savedRange.location, length: 0))
            }

            // 用户有选区 → 绝不滚动；否则按设置滚到底
            if !hadSelection && autoScroll && (wasAtBottom || isRunning) {
                tv.scrollToEndOfDocument(nil)
            }
        }

        private func isScrolledToBottom() -> Bool {
            guard let scroll = scrollView, let doc = scroll.documentView else { return true }
            let visible = scroll.contentView.bounds
            let maxY = doc.frame.height
            return visible.maxY >= maxY - 40
        }

        private func build(lines: [TranscriptLine], liveText: [Speaker: String],
                           fontSize: Double) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let mono = NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.72, weight: .regular)
            let body = NSFont.systemFont(ofSize: fontSize)
            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH:mm:ss"

            for line in lines {
                // 时间戳
                let stamp = "\(timeFmt.string(from: line.at))  "
                result.append(NSAttributedString(string: stamp, attributes: [
                    .font: mono,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]))
                // 说话人
                let who = "\(line.speaker.rawValue)  "
                result.append(NSAttributedString(string: who, attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize * 0.78, weight: .semibold),
                    .foregroundColor: NSColor(line.speaker.color)
                ]))
                // 正文
                result.append(NSAttributedString(string: line.text + "\n", attributes: [
                    .font: body,
                    .foregroundColor: NSColor.labelColor
                ]))
            }

            // 实时草稿（浅色斜体）
            for sp in Speaker.allCases {
                guard let live = liveText[sp], !live.isEmpty else { continue }
                result.append(NSAttributedString(string: "        ", attributes: [.font: mono]))
                result.append(NSAttributedString(string: "\(sp.rawValue)  ", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize * 0.78, weight: .semibold),
                    .foregroundColor: NSColor(sp.color).withAlphaComponent(0.55)
                ]))
                result.append(NSAttributedString(string: live + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .obliqueness: 0.14
                ]))
            }

            if result.length == 0 {
                return NSAttributedString(string: "点「开始转写」，对方的声音会实时出现在这里。\n\n这段文字随时可以选中复制（⌘A ⌘C）。", attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: NSColor.tertiaryLabelColor
                ])
            }
            return result
        }

        // 用户开始拖选时，标记状态（由 NSTextView 的鼠标事件驱动）
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = textView else { return }
            userIsSelecting = tv.selectedRange().length > 0
        }
    }
}

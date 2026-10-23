import SwiftUI
import AppKit

// MARK: - 主窗口

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ContentBody()
            .environmentObject(state.store)
    }
}

private struct ContentBody: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var store: TranscriptStore
    @State private var autoScroll = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.permissionState == .needScreen {
                PermissionBanner()
            }
            transcriptList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("出错了", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private func copyAll() {
        state.copyAll()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 14) {
            Button {
                state.toggle()
            } label: {
                Label(state.isRunning ? "停止" : "开始转写",
                      systemImage: state.isRunning ? "stop.fill" : "waveform")
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .tint(state.isRunning ? .red : .accentColor)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [.command])

            LevelMeter(level: state.levelOther, speaker: .other, active: state.isRunning && state.captureSystem)
            if state.captureMic {
                LevelMeter(level: state.levelMe, speaker: .me, active: state.isRunning)
            }

            Spacer()

            Text(state.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                state.toggleCaption()
            } label: {
                Image(systemName: state.showCaptionPanel ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
            }
            .help("字幕浮窗（⇧⌘K）— 可以叠在会议窗口上")

            Menu {
                Toggle("采集系统声音（对方）", isOn: $state.captureSystem)
                    .disabled(state.isRunning)
                Toggle("采集麦克风（我）", isOn: $state.captureMic)
                    .disabled(state.isRunning)
                Divider()
                Picker("识别语言", selection: $state.localeCode) {
                    Text("中文（普通话）").tag("zh-CN")
                    Text("English (US)").tag("en-US")
                    Text("日本語").tag("ja-JP")
                }
                .disabled(state.isRunning)
                Divider()
                Toggle("每句定稿自动复制到剪贴板", isOn: $state.autoCopy)
                if state.autoCopy {
                    Picker("复制范围", selection: $state.autoCopyScope) {
                        Text("只复制最新一句").tag("latest")
                        Text("复制全部内容").tag("all")
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Menu("字幕文件") {
                    ForEach(SubtitleExporter.Format.allCases) { fmt in
                        Toggle(fmt.displayName, isOn: Binding(
                            get: { state.subtitleFormats.contains(fmt) },
                            set: { on in
                                var set = state.subtitleFormats
                                if on { set.insert(fmt) } else { set.remove(fmt) }
                                if set.isEmpty { set = [.srt] }
                                state.subtitleFormats = set
                            }
                        ))
                    }
                    Divider()
                    Toggle("会议中实时刷新", isOn: $state.subtitleLive)
                    Toggle("字幕包含说话人", isOn: $state.subtitleWithSpeaker)
                    Divider()
                    Button("立即重新生成") { state.regenerateSubtitles() }
                        .disabled(store.lines.isEmpty)
                    Button("另存为…") { state.exportSubtitleInteractive() }
                        .disabled(store.lines.isEmpty)
                }
                Divider()
                Menu("历史会议") {
                    ForEach(state.sessionFolders.prefix(15), id: \.self) { dir in
                        Button(dir.lastPathComponent) {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                    if state.sessionFolders.isEmpty {
                        Text("还没有历史记录")
                    }
                    Divider()
                    Button("打开全部会议文件夹") { state.openRootFolder() }
                }
                Divider()
                Button("打开本次会议文件夹") { state.openOutputFolder() }
                Button("导出为文本…") { state.exportInteractive() }
                Divider()
                Button("权限设置…") { state.requestScreenPermission() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 转写列表

    private var transcriptList: some View {
        PlainTextPane(
            lines: store.lines,
            liveText: store.liveText,
            fontSize: state.fontSize,
            isRunning: state.isRunning,
            autoScroll: $autoScroll,
            onMagnify: { delta in state.adjustFontSize(delta) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if !store.lines.isEmpty {
                copyHint
            }
        }
    }

    /// 右上角的"一键复制"入口，随时可用
    private var copyHint: some View {
        HStack(spacing: 6) {
            Button {
                copyAll()
            } label: {
                Label(copied ? "已复制" : "复制全部", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Button {
                state.exportInteractive()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("导出为文本文件")
        }
        .padding(10)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $autoScroll) {
                Label("自动滚动", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.checkbox)

            Divider().frame(height: 14)

            // 字号调节：⌘+ / ⌘-
            HStack(spacing: 2) {
                Button {
                    state.adjustFontSize(-1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.borderless)
                .disabled(state.fontSize <= AppState.fontSizeRange.lowerBound)
                .help("缩小字号（⌘-）")

                Text("\(Int(state.fontSize))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22)
                    .help("当前正文字号")

                Button {
                    state.adjustFontSize(1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.borderless)
                .disabled(state.fontSize >= AppState.fontSizeRange.upperBound)
                .help("放大字号（⌘+）")
            }

            Divider().frame(height: 14)

            if let dir = store.sessionDirectory {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: {
                    Label(dir.lastPathComponent, systemImage: "folder")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("本次会议的全部文件（md / 字幕 / 录音）都在这个文件夹里")
            }

            // 字幕文件入口
            if !state.subtitleFiles.isEmpty {
                Menu {
                    ForEach(state.subtitleFiles, id: \.format) { item in
                        Button("\(item.format.rawValue.uppercased()) · \(item.url.lastPathComponent)") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                    }
                    Divider()
                    Button("另存为…") { state.exportSubtitleInteractive() }
                } label: {
                    Label("字幕", systemImage: "captions.bubble")
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("自动生成的字幕文件，点开可定位")
            }

            Spacer()

            Button {
                state.copyAll()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Label(copied ? "已复制" : "复制全文", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(store.lines.isEmpty)
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Text("\(store.lines.count) 句")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if state.isRefining {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.refineStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !store.lines.isEmpty && !state.isRunning {
                Button {
                    state.refineWithWhisper()
                } label: {
                    Label("Whisper 精修", systemImage: "wand.and.stars")
                }
                .help("用本地 Whisper large-v3-turbo 重新转写，准确率更高")
            }

            Button {
                state.exportSubtitleInteractive()
            } label: {
                Label("字幕", systemImage: "captions.bubble")
            }
            .disabled(store.lines.isEmpty)
            .help("导出 SRT / VTT / ASS 字幕文件")

            Button {
                state.exportInteractive()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(store.lines.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - 行

// MARK: - 权限提示条

private struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("还需要授权才能抓取会议声音")
                    .font(.callout.weight(.semibold))
                Text("macOS 要求 App 显式获得「屏幕与系统录音」权限才能读取系统音频（这是系统限制，不是偷看屏幕）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("去授权") { state.requestScreenPermission() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }
}

// MARK: - 音量条

private struct LevelMeter: View {
    let level: Float
    let speaker: Speaker
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: speaker.symbol)
                .font(.system(size: 9))
                .foregroundStyle(active ? speaker.color : .secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(speaker.color.opacity(active ? 0.85 : 0.25))
                    .frame(width: max(2, CGFloat(active ? level : 0) * 46))
            }
            .frame(width: 46, height: 4)
            .animation(.linear(duration: 0.1), value: level)
        }
        .help(speaker == .other ? "对方声音电平" : "我的声音电平")
    }
}

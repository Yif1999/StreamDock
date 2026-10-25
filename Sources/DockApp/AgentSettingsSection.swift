import AppKit
import ControlModules
import SwiftUI

/// The Codex and Claude reminders: whether events are coming in, and the hooks that send them,
/// loaded and restored from here. Both apps' hooks run the same small forwarder (`dock-hook`).
struct AgentSettingsSection: View {
    @State private var hookStates: [AIService: AgentHooks.State] = [:]
    @State private var message: String?
    @State private var confirmRemoval = false

    var body: some View {
        if let monitor = AgentMonitor.current {
            Section {
                LabeledContent("接收事件") {
                    if monitor.listening {
                        Label("正在接收", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("未能开启本机通道").foregroundStyle(.secondary)
                    }
                }
                ForEach(AIService.allCases, id: \.self) { service in
                    LabeledContent("\(service.name) 最近的事件") {
                        if let last = monitor.lastEvents[service] {
                            Text("\(last.event) · \(last.date.formatted(date: .omitted, time: .standard))")
                        } else {
                            Text("还没有收到").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("提醒只在 VibeCoding 场景的灯带上显示，状态全部来自下面的 hook（另外只看哪个应用在前台、是否退出），不读取两边的会话记录。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("灯带提醒") }

            Section {
                LabeledContent("事件转发程序") {
                    HStack {
                        Text(monitor.helperInstalled ? "已安装" : "未安装").foregroundStyle(.secondary)
                        if monitor.helperInstalled {
                            Button("移除", role: .destructive) { confirmRemoval = true }.buttonStyle(.glass)
                        } else {
                            Button("安装") { run { try monitor.installHelper() } }.buttonStyle(.glassProminent)
                        }
                    }
                }
                Text("两边的 hook 运行同一个小程序（\(AgentMonitor.helperPath)）：每有一个事件，它把应用、事件名和会话编号转给本程序，然后退出；不转发你的消息内容，不输出任何东西，本程序没运行时直接退出。加载 hook 时会自动安装，本程序启动时会把它更新到最新版。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AIService.allCases, id: \.self) { service in
                    LabeledContent(service.name) {
                        HStack {
                            Text(label(for: hookStates[service] ?? .notLoaded)).foregroundStyle(.secondary)
                            switch hookStates[service] ?? .notLoaded {
                            case .notLoaded:
                                Button("加载") { run { try monitor.loadHooks(service) } }.buttonStyle(.glassProminent)
                            case .loaded:
                                Button("还原") { run { try AgentHooks.restore(service) } }.buttonStyle(.glass)
                            case .outdated:
                                Button("重新加载") { run { try monitor.loadHooks(service) } }.buttonStyle(.glassProminent)
                                Button("还原") { run { try AgentHooks.restore(service) } }.buttonStyle(.glass)
                            }
                        }
                    }
                }
                Text("Codex 加载后要信任一次：在终端运行 /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex，输入 /hooks 审核并信任。Claude 已经打开的会话可能要重开才会用上。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).foregroundStyle(.red) }
                HStack {
                    Text("加载和还原只增删本程序的条目，写入前原文件会先备份。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("显示备份") {
                        try? FileManager.default.createDirectory(at: AgentHooks.backupDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AgentHooks.backupDirectory])
                    }.buttonStyle(.glass)
                }
            } header: { Text("hook") }
            .onAppear(perform: refresh)
            .confirmationDialog("移除事件转发程序？", isPresented: $confirmRemoval) {
                Button("还原两边的 hook 并移除", role: .destructive) { run { try monitor.removeHelper() } }
            } message: {
                Text("hook 离不开它：会先从 Claude 和 Codex 的配置里还原本程序加的 hook，再移除它。")
            }
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); message = nil } catch { message = error.localizedDescription }
        refresh()
    }

    private func refresh() {
        hookStates = Dictionary(uniqueKeysWithValues: AIService.allCases.map { ($0, AgentHooks.state(for: $0)) })
    }

    private func label(for state: AgentHooks.State) -> String {
        switch state {
        case .loaded: "已加载"
        case .notLoaded: "未加载"
        case .outdated: "只加载了一部分"
        }
    }
}

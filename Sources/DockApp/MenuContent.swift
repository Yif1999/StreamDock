import AppKit
import DockCore
import SwiftUI

struct MenuContent: View {
    let controller: DockController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.connection.summary)

        Divider()

        ForEach(controller.scenes.indices, id: \.self) { index in
            Toggle(controller.scenes[index].name, isOn: Binding(
                get: { controller.activeSceneIndex == index },
                set: { if $0 { controller.activateScene(at: index) } }
            ))
        }

        Divider()

        Button("设置…") {
            openWindow(id: SettingsView.windowID)
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Button("退出 StreamDock") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension DockController.Connection {
    var summary: String {
        switch self {
        case .searching: "未连接 · 等待 M18 插入"
        case .connecting: "正在连接 M18…"
        case .connected: "已连接 M18"
        case .failed: "M18 连接失败"
        }
    }
}

import ControlModules
import SwiftUI

struct OBSSettingsSection: View {
    private let client = OBSClient.shared
    @State private var slot = 0

    var body: some View {
        Section("OBS 控台 · 通用控制第 3 页") {
            LabeledContent("状态", value: client.connection.description)
            HStack {
                Button("打开 OBS") { client.openOBS() }
                Button("重新连接") { client.reconnect() }
            }.buttonStyle(.glass)
            Text("在 OBS 的“工具 → WebSocket 服务器设置”中启用服务并保留身份验证。自动读取本机配置，密码不会复制到 StreamDock 设置中。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = client.actionError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Picker("配置按键", selection: $slot) {
                ForEach(0..<15, id: \.self) { index in
                    Text("第 \(index / 5 + 1) 排 · 第 \(index % 5 + 1) 键").tag(index)
                }
            }
            Picker("功能", selection: Binding(get: { client.bindings[slot].action }, set: { value in
                client.setBinding(OBSBinding(action: value), at: slot)
            })) {
                ForEach(OBSAction.allCases) { action in Text(action.title).tag(action) }
            }
            targetControls
            if client.bindings[slot].action == .saveReplay {
                Text("需要先在 OBS 启动回放缓存；也可将另一个按键配置为“回放缓存”。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("工作室模式下，场景键选择预览场景，再按“执行转场”送到节目画面。关闭工作室模式时直接切换节目场景。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { client.start() }
    }

    @ViewBuilder private var targetControls: some View {
        let binding = client.bindings[slot]
        switch binding.action {
        case .scene, .inputMute, .hotkey:
            let choices = binding.action == .scene ? client.scenes : binding.action == .inputMute ? client.audioInputs : client.hotkeys
            Picker("目标", selection: field(\.target)) {
                Text(binding.action == .hotkey ? "请选择" : "自动第 \(binding.automaticIndex + 1) 项").tag("")
                if !binding.target.isEmpty && !choices.contains(binding.target) {
                    Text("\(binding.target)（离线）").tag(binding.target)
                }
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
        case .sourceVisibility:
            Picker("所属场景", selection: Binding(get: { binding.scene }, set: { value in
                var changed = client.bindings[slot]; changed.scene = value; changed.itemID = nil; changed.target = ""
                client.setBinding(changed, at: slot)
            })) {
                Text("当前节目场景").tag("")
                if !binding.scene.isEmpty && !client.scenes.contains(binding.scene) { Text("\(binding.scene)（离线）").tag(binding.scene) }
                ForEach(client.scenes, id: \.self) { Text($0).tag($0) }
            }
            Picker("来源", selection: Binding<Int?>(get: { binding.itemID }, set: { id in
                var changed = client.bindings[slot]
                changed.itemID = id
                let scene = changed.scene.isEmpty ? client.programScene : changed.scene
                changed.target = client.sceneItems.first { $0.scene == scene && $0.itemID == id }?.name ?? ""
                client.setBinding(changed, at: slot)
            })) {
                Text("自动第 \(binding.automaticIndex + 1) 项").tag(Int?.none)
                let items = client.sceneItems.filter { $0.scene == (binding.scene.isEmpty ? client.programScene : binding.scene) }
                if let id = binding.itemID, !items.contains(where: { $0.itemID == id }) {
                    Text("\(binding.target)（离线）").tag(Int?.some(id))
                }
                ForEach(items) { item in Text("\(item.name) · \(item.itemID)").tag(Int?.some(item.itemID)) }
            }
        default: EmptyView()
        }
    }

    private func field(_ key: WritableKeyPath<OBSBinding, String>) -> Binding<String> {
        Binding(get: { client.bindings[slot][keyPath: key] }, set: { value in
            var binding = client.bindings[slot]; binding[keyPath: key] = value
            client.setBinding(binding, at: slot)
        })
    }
}

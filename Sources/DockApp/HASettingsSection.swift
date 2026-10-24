import ControlModules
import SwiftUI

struct HASettingsSection: View {
    private let client = HAClient.shared
    @State private var address = ""
    @State private var token = ""
    @State private var slot = 0
    @State private var search = ""
    @State private var showConnection = true

    var body: some View {
        Section {
            LabeledContent("状态", value: client.connection.description)
            DisclosureGroup("连接设置", isExpanded: $showConnection) {
                TextField("服务器地址", text: $address, prompt: Text("http://homeassistant.local:8123"))
                SecureField("访问令牌", text: $token, prompt: Text("已有令牌时留空即可"))
                Text("在 HA 的个人资料 → 安全中创建长期访问令牌。令牌仅保存在这台 Mac 的钥匙串中。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存并连接") {
                        if client.configure(address: address, token: token) { token = ""; address = client.address }
                    }.buttonStyle(.glassProminent)
                    Button("移除令牌", role: .destructive) { client.removeToken(); token = "" }
                }
            }
            HStack {
                Button("打开 HA") { client.openDashboard() }.disabled(client.address.isEmpty)
                Button("重新连接") { client.reconnect() }.disabled(client.address.isEmpty)
            }.buttonStyle(.glass)
            if let error = client.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("Home Assistant") }

        Section {
            keyGrid
            Picker("功能", selection: Binding(get: { client.bindings[slot].action }, set: { action in
                client.setBinding(HABinding(action: action), at: slot)
                search = ""
            })) {
                ForEach(HAAction.allCases) { action in Text(action.title).tag(action) }
            }
            if client.bindings[slot].action == .safePower {
                Text("通电时需持续按住 1 秒才断电，松手、翻页或断线即取消；断电时短按恢复供电。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if client.bindings[slot].action != .none {
                TextField("搜索设备", text: $search, prompt: Text("名称或实体 ID"))
                entityPicker
                TextField("按键名称", text: field(\.label), prompt: Text("默认使用设备名称"))
                if let entity = client.entity(for: client.bindings[slot]) {
                    LabeledContent("当前状态", value: entity.displayState)
                }
            }
        } header: { Text("第 2 页按键 · 第 \(slot / 5 + 1) 排，第 \(slot % 5 + 1) 列") }
        footer: { Text("选择上方按键，再指定功能和设备。更改自动保存；只显示状态的按键不会控制设备。") }
        .onAppear {
            address = client.address
            showConnection = client.connection != .ready
            client.start()
        }
    }
    private var keyGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(0..<15, id: \.self) { index in
                let binding = client.bindings[index]
                Button {
                    slot = index; search = ""
                } label: {
                    VStack(spacing: 4) {
                        Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        Text(binding.action == .none ? "留空" : binding.label.isEmpty ? client.entity(for: binding)?.name ?? binding.action.title : binding.label)
                            .font(.caption).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
                .tint(index == slot ? .accentColor : .secondary)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(index == slot ? Color.accentColor : .clear, lineWidth: 2))
                .accessibilityLabel("第 \(index / 5 + 1) 排，第 \(index % 5 + 1) 列")
                .accessibilityAddTraits(index == slot ? .isSelected : [])
            }
        }.padding(.vertical, 4)
    }
    private var entityPicker: some View {
        let binding = client.bindings[slot]
        let choices = client.choices(for: binding.action).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search)
        }
        return Picker("设备或实体", selection: field(\.entityID)) {
            Text("请选择").tag("")
            if !binding.entityID.isEmpty && !choices.contains(where: { $0.id == binding.entityID }) {
                Text(client.entity(for: binding)?.name ?? "\(binding.entityID)（离线）").tag(binding.entityID)
            }
            ForEach(choices) { entity in Text("\(entity.name) · \(entity.id)").tag(entity.id) }
        }
    }
    private func field(_ key: WritableKeyPath<HABinding, String>) -> Binding<String> {
        Binding(get: { client.bindings[slot][keyPath: key] }, set: { value in
            var binding = client.bindings[slot]; binding[keyPath: key] = value
            client.setBinding(binding, at: slot)
        })
    }
}

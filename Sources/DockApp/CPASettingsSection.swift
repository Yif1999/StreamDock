import ControlModules
import SwiftUI

struct CPASettingsSection: View {
    private let client = CPAClient.shared
    @State private var address = ""
    @State private var key = ""

    var body: some View {
        Section {
            LabeledContent("状态", value: client.status.description)
            TextField("CPA 地址", text: $address, prompt: Text("https://cpa.example.com"))
            SecureField("管理密钥", text: $key, prompt: Text("已有密钥时留空即可"))
            Text("用于读取 Codex 和 Claude 的额度：CPA 用服务器上保存的账号查询，账号凭据不会传到这台 Mac。管理密钥只保存在钥匙串中，只发送查询请求，不会使用重置卡或改动账号。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存并读取") {
                    if client.configure(address: address, key: key) { key = ""; address = client.address }
                }.buttonStyle(.glassProminent)
                Button("立即刷新") { client.refreshNow() }.disabled(client.address.isEmpty)
                Button("移除密钥", role: .destructive) { client.removeKey(); key = "" }
            }.buttonStyle(.glass)
        } header: { Text("CPA 额度来源") }
        ForEach(AIService.allCases, id: \.self) { service in
            Section(service.name) {
                Picker("账号", selection: Binding(get: { client.account(for: service)?.id }, set: { client.choose($0, for: service) })) {
                    if client.choices(for: service).isEmpty { Text("未读取到账号").tag(String?.none) }
                    ForEach(client.choices(for: service)) { account in
                        Text(account.active ? account.email : "\(account.email)（不可用）").tag(String?.some(account.id))
                    }
                }
                if let quota = client.quotas[service] {
                    if let session = quota.session { LabeledContent("5 小时剩余", value: "\(Int((session.remaining * 100).rounded()))%") }
                    if let weekly = quota.weekly { LabeledContent("每周剩余", value: "\(Int((weekly.remaining * 100).rounded()))%") }
                    if let resets = quota.resetCredits { LabeledContent("重置卡", value: "\(resets) 张") }
                    if let credits = quota.credits { LabeledContent("Credits 余额", value: credits.formatted(.number.precision(.fractionLength(0)))) }
                }
                if let error = client.errors[service] {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onAppear { address = client.address }
    }
}

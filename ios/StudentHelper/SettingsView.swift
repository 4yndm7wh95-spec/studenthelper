import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var configuration = ModelConfiguration()
    @State private var mode = ModelConnectionMode.direct
    @State private var key = ""
    @State private var credentialEndpoint: String?
    @State private var serviceAddress = ""
    @State private var advanced = false
    @State private var checking = false
    @State private var feedback: String?
    @State private var succeeded = false
    @State private var clearConfirmation = false
    @State private var removeKeyConfirmation = false
    private let keychain = ModelKeychain()
    var body: some View {
        Form {
            Section("模型") {
                if mode == .direct {
                    LabeledContent("当前模型", value: configuration.title)
                    SecureField("API Key", text: Binding(get: { key }, set: { key = $0; feedback = nil }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("API Key").privacySensitive().accessibilityIdentifier("model-key")
                } else {
                    TextField("服务地址", text: $serviceAddress).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                HStack {
                    Button("保存") { saveConfiguration() }.accessibilityIdentifier("save-model")
                    Spacer()
                    Button { Task { await checkConnection() } } label: {
                        HStack { if checking { ProgressView() }; Text("测试连接") }
                    }.accessibilityIdentifier("test-model")
                }.buttonStyle(.borderless)
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(succeeded ? Notebook.accent : Notebook.secondary) }
            }.disabled(checking)
            Section {
                DisclosureGroup("高级设置", isExpanded: $advanced) {
                    Picker("连接方式", selection: $mode) {
                        Text("直接连接模型").tag(ModelConnectionMode.direct)
                        Text("自己的服务").tag(ModelConnectionMode.service)
                    }
                    if mode == .direct {
                        TextField("接口地址", text: $configuration.address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityLabel("接口地址")
                        TextField("模型名称", text: $configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("模型名称")
                        if !key.isEmpty { Button("移除已保存密钥", role: .destructive) { removeKeyConfirmation = true } }
                    }
                }
            }.disabled(checking)
            Section("数据") {
                LabeledContent("本机数据", value: store.dataSize)
                LabeledContent("同步", value: "未开启")
                Button("清空全部聊天", role: .destructive) { clearConfirmation = true }
            }
            Section("关于") { LabeledContent("一步", value: "0.4.0") }
        }.scrollContentBackground(.hidden).background(Notebook.paper).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .onAppear { loadConfiguration() }
        .onChange(of: configuration.address) { _, _ in loadKeyForEndpoint(); feedback = nil }
        .onChange(of: configuration.model) { _, _ in feedback = nil }
        .onChange(of: mode) { _, _ in feedback = nil }
        .alert("移除密钥？", isPresented: $removeKeyConfirmation) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                do { try keychain.remove(for: configuration); key = ""; succeeded = true; feedback = "密钥已移除。" }
                catch { report(error) }
            }
        }
        .alert("清空全部聊天？", isPresented: $clearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearChats() }
        } message: { Text("所有消息、草稿和题目记录都会从本机删除。课程和文件名会保留。") }
    }
    private func loadConfiguration() {
        configuration = ModelConfiguration.load(); mode = ModelConfiguration.mode; serviceAddress = store.backend
        loadKeyForEndpoint()
    }
    private func loadKeyForEndpoint() {
        let endpoint = configuration.endpoint?.absoluteString
        guard credentialEndpoint != endpoint else { return }
        credentialEndpoint = endpoint; key = ""
        guard endpoint != nil else { return }
        do { key = try keychain.read(for: configuration) } catch { report(error) }
    }
    @discardableResult private func saveConfiguration() -> Bool {
        do {
            if mode == .direct {
                guard configuration.endpoint != nil else { throw ModelConnectionError.address }
                guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelConnectionError.model }
                try keychain.save(key, for: configuration)
                configuration.save()
            } else {
                guard store.validateBackend(serviceAddress) != nil else { feedback = "请填写 HTTPS 地址或局域网服务地址。"; succeeded = false; return false }
                store.backend = serviceAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            ModelConfiguration.mode = mode
            succeeded = true; feedback = "已保存。"
            return true
        } catch { report(error); return false }
    }
    private func checkConnection() async {
        guard saveConfiguration() else { return }
        checking = true; feedback = nil
        defer { checking = false }
        do {
            if mode == .direct {
                _ = try await ModelClient.complete(configuration: configuration, key: key,
                    messages: [ModelMessage(role: "user", content: "只回复 OK")], maxTokens: 16)
            } else {
                guard let url = store.validateBackend(serviceAddress) else { throw ModelConnectionError.address }
                var request = URLRequest(url: url.appendingPathComponent("api/health")); request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let health = try? JSONDecoder().decode(Health.self, from: data), health.ready else {
                    succeeded = false; feedback = "服务尚未配置模型，或地址无法使用。"; return
                }
            }
            succeeded = true; feedback = "已连接，可以开始做题。"
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        succeeded = false
        feedback = (error as? ModelConnectionError)?.errorDescription ?? "连接失败，请检查网络后重试。"
    }
    private struct Health: Decodable { var ready: Bool }
}

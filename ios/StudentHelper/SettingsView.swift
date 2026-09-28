import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var address = ""
    @State private var checking = false
    @State private var connectionResult: String?
    @State private var clearConfirmation = false
    var body: some View {
        Form {
            Section("连接") {
                TextField("https://… 或 http://192.168.x.x:4174", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).accessibilityLabel("服务地址")
                Button { Task { await checkConnection() } } label: { HStack { Label("测试连接", systemImage: "network"); Spacer(); if checking { ProgressView() } } }.disabled(checking)
                if let connectionResult { Text(connectionResult).font(.footnote).foregroundStyle(Notebook.secondary) }
                Text("密钥只在服务端，本机不保存。").font(.footnote).foregroundStyle(Notebook.secondary)
            }
            Section("数据") {
                LabeledContent("本机数据", value: store.dataSize)
                Text("当前仅本机保存，尚未接入云同步。").font(.footnote).foregroundStyle(Notebook.secondary)
                Button("清空全部聊天", role: .destructive) { clearConfirmation = true }
            }
            Section("关于") { LabeledContent("一步", value: "0.2.0") }
        }.scrollContentBackground(.hidden).background(Notebook.paper).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .onAppear { address = store.backend }
        .onDisappear { store.backend = address.trimmingCharacters(in: .whitespacesAndNewlines) }
        .alert("清空全部聊天？", isPresented: $clearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.clearChats() }
        } message: { Text("所有消息、草稿和题目记录都会从本机删除。课程和文件名会保留。") }
    }
    private func checkConnection() async {
        guard let url = store.validateBackend(address) else { connectionResult = "请填写 HTTPS 地址，或局域网内的 HTTP 地址。"; return }
        checking = true; connectionResult = nil
        defer { checking = false }
        store.backend = address.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var request = URLRequest(url: url.appendingPathComponent("api/health")); request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { connectionResult = "服务地址无法使用。"; return }
            let health = try JSONDecoder().decode(Health.self, from: data)
            connectionResult = health.ready ? "可用" : "服务端尚未配置教学密钥。"
        } catch { connectionResult = "连接失败，请检查地址和网络。" }
    }
    private struct Health: Decodable { var ready: Bool }
}

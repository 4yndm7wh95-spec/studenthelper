import Foundation
import Security

enum ModelConnectionMode: String, CaseIterable, Identifiable {
    case direct, service
    var id: String { rawValue }
}

struct ModelConfiguration: Equatable {
    var address = "https://api.deepseek.com"
    var model = "deepseek-flash"
    var endpoint: URL? {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        components.scheme = "https"; components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.path = path
        return components.url
    }
    var title: String { model == "deepseek-flash" ? "DeepSeek V4.1 Flash" : model }
    static func load(from defaults: UserDefaults = .standard) -> ModelConfiguration {
        ModelConfiguration(address: defaults.string(forKey: "modelAddress") ?? "https://api.deepseek.com",
                           model: defaults.string(forKey: "modelName") ?? "deepseek-flash")
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "modelAddress")
        defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "modelName")
    }
    static var mode: ModelConnectionMode {
        get { ModelConnectionMode(rawValue: UserDefaults.standard.string(forKey: "modelConnectionMode") ?? "") ?? .direct }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "modelConnectionMode") }
    }
}

struct ModelKeychain {
    private let service: String
    init(service: String = "com.studenthelper.yibu.model-keys") { self.service = service }
    private func query(for configuration: ModelConfiguration) throws -> [String: Any] {
        guard let endpoint = configuration.endpoint else { throw ModelConnectionError.address }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: endpoint.absoluteString,
                kSecAttrSynchronizable as String: false]
    }
    func read(for configuration: ModelConfiguration) throws -> String {
        var query = try query(for: configuration)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw ModelConnectionError.keychain(status) }
        return value
    }
    func save(_ key: String, for configuration: ModelConfiguration) throws {
        let clean = try ModelClient.validatedKey(key)
        let query = try query(for: configuration)
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; attributes.forEach { item[$0.key] = $0.value }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ModelConnectionError.keychain(addStatus) }
        } else if status != errSecSuccess { throw ModelConnectionError.keychain(status) }
    }
    func remove(for configuration: ModelConfiguration) throws {
        let status = SecItemDelete(try query(for: configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ModelConnectionError.keychain(status) }
    }
}

struct ModelMessage: Codable {
    let role: String
    let content: ModelContent
    init(role: String, content: String) { self.role = role; self.content = .text(content) }
    init(role: String, text: String, imageURLs: [String]) {
        self.role = role
        self.content = imageURLs.isEmpty ? .text(text) : .parts(
            [ModelContentPart(type: "text", text: text.isEmpty ? "请从图中的题目开始，一次只教一步。" : text)] +
            imageURLs.map { ModelContentPart(type: "image_url", imageURL: .init(url: $0)) })
    }
}

enum ModelContent: Codable {
    case text(String), parts([ModelContentPart])
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { self = .text(text) }
        else { self = .parts(try container.decode([ModelContentPart].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self { case .text(let text): try container.encode(text); case .parts(let parts): try container.encode(parts) }
    }
}

struct ModelContentPart: Codable {
    var type: String
    var text: String?
    var imageURL: ImageURL?
    struct ImageURL: Codable { var url: String }
    enum CodingKeys: String, CodingKey { case type, text; case imageURL = "image_url" }
}

enum ModelConnectionError: LocalizedError {
    case address, model, key, keychain(OSStatus), status(Int), response, empty
    var errorDescription: String? {
        switch self {
        case .address: return "接口地址需要以 https:// 开头。"
        case .model: return "请填写模型名称。"
        case .key: return "在设置的‘模型’里填写 API Key。"
        case .keychain: return "密钥无法保存或读取，请解锁手机后重试。"
        case .status(401), .status(403): return "密钥无效或没有使用权限，请检查 API Key。"
        case .status(402): return "模型账户余额不足。"
        case .status(404): return "请检查接口地址和模型名称。"
        case .status(429): return "请求太频繁，请稍后再试。"
        case .status: return "模型服务暂时无法回复，请稍后再试。"
        case .response: return "接口返回格式不兼容，请检查模型设置。"
        case .empty: return "模型没有返回文字，请重试。"
        }
    }
}

struct ModelClient {
    static let teachingPrompt = #"你是大学数学老师。中文回复，一次只教一个小步骤，通常1至3句短句和必要公式，只问一个检查当前步骤的问题。不要比喻、长篇解析或自我介绍。学生不会就直接示范当前一步，不反问教学目标。用户明确要答案时给简洁完整答案。同一对话可以连续做多题；收到多道题时只从第一道开始，直到学生提供或选择下一题。不要假称学生已掌握知识。独立公式必须独占一行，用 \[公式\] 包裹；句子内的公式用 \(公式\) 包裹。正确使用条件概率与交集符号，P(A|B)=P(A∩B)/P(B)，不能无依据省去交集。输出标准 LaTeX，不要写 HTML 或代码块。"#
    static func validatedKey(_ key: String) throws -> String {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ModelConnectionError.key }
        return clean
    }
    static func request(configuration: ModelConfiguration, key: String, messages: [ModelMessage], maxTokens: Int = 1400) throws -> URLRequest {
        guard let endpoint = configuration.endpoint else { throw ModelConnectionError.address }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ModelConnectionError.model }
        let cleanKey = try validatedKey(key)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 95)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + cleanKey, forHTTPHeaderField: "Authorization")
        let wireMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
        var body: [String: Any] = ["model": model, "messages": wireMessages, "max_tokens": maxTokens, "stream": false]
        if endpoint.host == "api.deepseek.com" { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func complete(configuration: ModelConfiguration, key: String, messages: [ModelMessage], maxTokens: Int = 1400, session: URLSession = .shared) async throws -> String {
        let request = try request(configuration: configuration, key: key, messages: messages, maxTokens: maxTokens)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelConnectionError.response }
        guard (200..<300).contains(http.statusCode) else { throw ModelConnectionError.status(http.statusCode) }
        guard let result = try? JSONDecoder().decode(Completion.self, from: data) else { throw ModelConnectionError.response }
        let text = result.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw ModelConnectionError.empty }
        return text
    }
    private struct Completion: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
    }
}

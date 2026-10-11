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
    case address, model, key, keychain(OSStatus), status(Int), response, empty, teachingReply
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
        case .teachingReply: return "这次回复没有整理好，请重试。"
        }
    }
}

struct ModelClient {
    static let teachingPrompt = TeachingInstructions.base
    static func instructions(for messages: [ModelMessage]) -> String {
        messages.contains { $0.role == "assistant" } ? teachingPrompt : teachingPrompt + "\n\n" + TeachingInstructions.opening
    }
    static func validatedKey(_ key: String) throws -> String {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ModelConnectionError.key }
        return clean
    }
    private static func usesTeachingProtocol(configuration: ModelConfiguration, messages: [ModelMessage]) -> Bool {
        guard configuration.endpoint?.host == "api.deepseek.com",
              configuration.model.trimmingCharacters(in: .whitespacesAndNewlines) == TeachingInstructions.model else { return false }
        return messages.contains { message in
            guard message.role == "system", case .text(let text) = message.content else { return false }
            return text.contains(TeachingInstructions.base)
        }
    }

    static func request(configuration: ModelConfiguration, key: String, messages: [ModelMessage], maxTokens: Int? = nil) throws -> URLRequest {
        try request(configuration: configuration, key: key, messages: messages, maxTokens: maxTokens, retry: false)
    }

    private static func request(configuration: ModelConfiguration, key: String, messages: [ModelMessage], maxTokens: Int?, retry: Bool) throws -> URLRequest {
        guard let endpoint = configuration.endpoint else { throw ModelConnectionError.address }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ModelConnectionError.model }
        let cleanKey = try validatedKey(key)
        let teaching = usesTeachingProtocol(configuration: configuration, messages: messages)
        let prepared = teaching ? messages.map { message -> ModelMessage in
            guard message.role == "system", case .text(let text) = message.content,
                  text.contains(TeachingInstructions.base) else { return message }
            var content = TeachingInstructions.contract + "\n\n" + text + "\n\n" + TeachingInstructions.outputInstruction
            if retry { content += "\n\n" + TeachingInstructions.retry }
            return ModelMessage(role: message.role, content: content)
        } : messages
        let budget = maxTokens ?? (teaching ? TeachingInstructions.maxTokens : 1400)
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 95)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + cleanKey, forHTTPHeaderField: "Authorization")
        let wireMessages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared))
        var body: [String: Any] = ["model": model, "messages": wireMessages,
                                 "max_tokens": teaching && retry ? max(budget, TeachingInstructions.maxTokens) : budget,
                                 "stream": false]
        if teaching {
            body["thinking"] = ["type": TeachingInstructions.thinkingType]
            body["reasoning_effort"] = TeachingInstructions.reasoningEffort
            body["response_format"] = ["type": TeachingInstructions.responseFormatType]
        } else if endpoint.host == "api.deepseek.com" { body["thinking"] = ["type": "disabled"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func complete(configuration: ModelConfiguration, key: String, messages: [ModelMessage], maxTokens: Int? = nil, session: URLSession = .shared) async throws -> String {
        let teaching = usesTeachingProtocol(configuration: configuration, messages: messages)
        for attempt in 0...(teaching ? 1 : 0) {
            let request = try request(configuration: configuration, key: key, messages: messages, maxTokens: maxTokens, retry: attempt > 0)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ModelConnectionError.response }
            guard (200..<300).contains(http.statusCode) else { throw ModelConnectionError.status(http.statusCode) }
            guard let result = try? JSONDecoder().decode(Completion.self, from: data) else { throw ModelConnectionError.response }
            let choice = result.choices.first
            let text = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if teaching {
                if choice?.finishReason != "length", let answer = try? TeachingReply.decode(text) { return answer }
                if attempt == 0 { continue }
                throw ModelConnectionError.teachingReply
            }
            guard choice?.message.invalidContent != true else { throw ModelConnectionError.response }
            guard !text.isEmpty else { throw ModelConnectionError.empty }
            return text
        }
        throw ModelConnectionError.teachingReply
    }
    private struct Completion: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case message; case finishReason = "finish_reason" }
        }
        struct Message: Decodable {
            let content: String?
            let invalidContent: Bool
            enum CodingKeys: String, CodingKey { case content }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if !container.contains(.content) {
                    content = nil; invalidContent = false
                } else if try container.decodeNil(forKey: .content) {
                    content = nil; invalidContent = false
                } else if let text = try? container.decode(String.self, forKey: .content) {
                    content = text; invalidContent = false
                } else {
                    content = nil; invalidContent = true
                }
            }
        }
    }
}

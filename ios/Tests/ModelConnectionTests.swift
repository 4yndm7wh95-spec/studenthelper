import XCTest
@testable import StudentHelper

final class ModelConnectionTests: XCTestCase {
    func testEndpointNormalization() {
        let examples = [
            ("https://API.DeepSeek.com/", "https://api.deepseek.com/chat/completions"),
            ("https://api.deepseek.com:443/v1/", "https://api.deepseek.com/v1/chat/completions"),
            ("https://provider.example/v1/chat/completions/", "https://provider.example/v1/chat/completions")
        ]
        for (address, expected) in examples {
            XCTAssertEqual(ModelConfiguration(address: address).endpoint?.absoluteString, expected)
        }
    }

    func testOpeningInstructionsOnlyApplyBeforeFirstTeacherReply() {
        let first = ModelClient.instructions(for: [ModelMessage(role: "user", content: "零基础，带我做题")])
        XCTAssertTrue(first.contains(TeachingInstructions.opening))
        let continued = ModelClient.instructions(for: [ModelMessage(role: "user", content: "零基础"), ModelMessage(role: "assistant", content: "先看题目要做什么。"), ModelMessage(role: "user", content: "明白了")])
        XCTAssertFalse(continued.contains(TeachingInstructions.opening))
        XCTAssertTrue(continued.contains(TeachingInstructions.base))
    }

    func testRejectsUnsafeAddressesAndInvalidKeys() {
        for address in ["http://api.deepseek.com", "https://user:password@example.com", "https://example.com?key=secret", "https://example.com#section", "not a URL"] {
            XCTAssertNil(ModelConfiguration(address: address).endpoint)
        }
        for key in ["", "  ", "secret\r\nInjected: header", "two words"] {
            XCTAssertThrowsError(try ModelClient.validatedKey(key))
        }
        XCTAssertEqual(try ModelClient.validatedKey("  test-key\n"), "test-key")
    }

    func testRequestCarriesTeacherInstructionsAndAuthorization() throws {
        let request = try ModelClient.request(configuration: ModelConfiguration(), key: "test-key",
            messages: [ModelMessage(role: "system", content: ModelClient.teachingPrompt), ModelMessage(role: "user", content: "这一步不懂")])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], TeachingInstructions.thinkingType)
        XCTAssertEqual(body["reasoning_effort"] as? String, TeachingInstructions.reasoningEffort)
        XCTAssertEqual(body["max_tokens"] as? Int, TeachingInstructions.maxTokens)
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], TeachingInstructions.responseFormatType)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertTrue(messages.first?["content"]?.contains(TeachingInstructions.base) == true)
        XCTAssertTrue(messages.first?["content"]?.contains(TeachingInstructions.contract) == true)
        XCTAssertEqual(messages.first?["content"], TeachingInstructions.contract + "\n\n" + TeachingInstructions.base + "\n\n" + TeachingInstructions.outputInstruction)
        XCTAssertEqual(messages.last?["content"], "这一步不懂")
        let custom = try ModelClient.request(configuration: ModelConfiguration(address: "https://provider.example/v1", model: "custom-model"), key: "other-key", messages: [])
        let customBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(custom.httpBody)) as? [String: Any])
        XCTAssertNil(customBody["thinking"])
        XCTAssertNil(customBody["reasoning_effort"])
        XCTAssertNil(customBody["response_format"])
        XCTAssertEqual(customBody["max_tokens"] as? Int, 1400)
        XCTAssertEqual(customBody["model"] as? String, "custom-model")
    }

    func testModelProbeDoesNotUseTeachingProtocolOrThinkingBudget() throws {
        let request = try ModelClient.request(configuration: ModelConfiguration(), key: "test-key",
            messages: [ModelMessage(role: "user", content: "只回复 OK")], maxTokens: 16)
        let body = try requestBody(request)
        XCTAssertEqual(body["max_tokens"] as? Int, 16)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["response_format"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "只回复 OK")
    }

    func testCustomProviderAndOtherModelsKeepTheirOriginalInstructions() throws {
        for configuration in [ModelConfiguration(address: "https://provider.example/v1", model: "deepseek-flash"),
                              ModelConfiguration(model: "custom-model")] {
            let messages = [ModelMessage(role: "system", content: TeachingInstructions.base), ModelMessage(role: "user", content: "这一步不会")]
            let body = try requestBody(ModelClient.request(configuration: configuration, key: "test-key", messages: messages))
            XCTAssertEqual(body["max_tokens"] as? Int, 1400)
            XCTAssertNil(body["response_format"])
            XCTAssertNil(body["reasoning_effort"])
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], TeachingInstructions.base)
        }
    }

    func testTeachingBlocksHideProtocolMetadataAndReasoning() async throws {
        let content = try teachingFrame(["先保留乘在前面的3。", #"\((3x^2)'=3(x^2)'\)"#], focus: "内部焦点", prerequisite: "内部记录")
        let session = makeSession(status: 200, body: try completion(content, reasoning: "不应展示或回传的思考文本"))
        defer { session.invalidateAndCancel() }
        let messages = teachingMessages()
        let answer = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: messages, session: session)
        XCTAssertEqual(answer, "先保留乘在前面的3。\n\n" + #"\((3x^2)'=3(x^2)'\)"#)
        XCTAssertFalse(answer.contains("内部焦点"))
        XCTAssertFalse(answer.contains("内部记录"))
        XCTAssertFalse(answer.contains("思考文本"))
        XCTAssertEqual(StubProtocol.requests.count, 1)
        let history = try XCTUnwrap(try requestBody(XCTUnwrap(StubProtocol.requests.first))["messages"] as? [[String: String]])
        XCTAssertEqual(history.dropFirst().map { $0["content"] ?? "" }, ["旧题怎么做", "旧题的一步", "换一道题，只问前面的3如何处理"])
        XCTAssertFalse(history.contains { ($0["content"] ?? "").contains("reasoning_content") })
    }

    func testInvalidTeachingContentRetriesOnceAndPreservesHistory() async throws {
        let valid = try teachingFrame(["乘在最前面的3保留。"])
        for invalid in ["   ", "不是JSON", "{\"intent\":\"local\"}"] {
            let session = makeSession(responses: [StubResponse(status: 200, body: try completion(invalid)),
                                                  StubResponse(status: 200, body: try completion(valid))])
            defer { session.invalidateAndCancel() }
            let answer = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: teachingMessages(), session: session)
            XCTAssertEqual(answer, "乘在最前面的3保留。")
            let requests = StubProtocol.requests
            XCTAssertEqual(requests.count, 2)
            let original = try XCTUnwrap(try requestBody(requests[0])["messages"] as? [[String: String]])
            let retried = try XCTUnwrap(try requestBody(requests[1])["messages"] as? [[String: String]])
            XCTAssertEqual(Array(original.dropFirst()), Array(retried.dropFirst()))
            XCTAssertTrue(retried.first?["content"]?.contains(TeachingInstructions.retry) == true)
            XCTAssertFalse(retried.contains { ($0["content"] ?? "").contains(invalid) && $0["role"] == "assistant" })
        }
    }

    func testMalformedTeachingFramesStopAfterOneRetry() async throws {
        let session = makeSession(responses: [StubResponse(status: 200, body: try completion("残片一")),
                                              StubResponse(status: 200, body: try completion("残片二")),
                                              StubResponse(status: 200, body: try completion(try teachingFrame(["不能出现第三次请求"])) )])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: teachingMessages(), session: session)
            XCTFail("Invalid protocol text must never become a chat message")
        } catch {
            guard case ModelConnectionError.teachingReply = error else { return XCTFail("Expected a teaching reply error") }
        }
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testLengthFinishReasonNeverDisplaysTruncatedBlocks() async throws {
        let content = try teachingFrame(["不应显示截断的回复。"])
        let session = makeSession(responses: [StubResponse(status: 200, body: try completion(content, finish: "length")),
                                              StubResponse(status: 200, body: try completion(content, finish: "length"))])
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: teachingMessages(), session: session)
            XCTFail("A valid-looking frame with length finish reason must be rejected")
        } catch { XCTAssertTrue(error is ModelConnectionError) }
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testTeachingHTTPAndNetworkFailuresAreNotRetried() async throws {
        for response in [StubResponse(status: 429, body: "private trace"),
                         StubResponse(status: 200, body: "", error: URLError(.notConnectedToInternet))] {
            let session = makeSession(responses: [response])
            defer { session.invalidateAndCancel() }
            do {
                _ = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: teachingMessages(), session: session)
                XCTFail("Transport failures must be reported")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private trace")) }
            XCTAssertEqual(StubProtocol.requests.count, 1)
        }
    }

    func testTeachingFrameScopeAndCompleteAnswerException() throws {
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(Array(repeating: "一步", count: 5))))
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame([String(repeating: "中", count: 61)])))
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(Array(repeating: String(repeating: "中", count: 31), count: 4))))
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(["回答"], intent: "full", action: "meaning")))
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(["回答"], prerequisiteReady: false)))
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(["回答"], focus: String(repeating: "a", count: 121))))
        let answer = try teachingFrame(Array(repeating: "完整答案中必须保留的依据。", count: 8), intent: "full", action: "complete")
        XCTAssertEqual(try TeachingReply.decode(answer).components(separatedBy: "\n\n").count, 8)
        XCTAssertThrowsError(try TeachingReply.decode(teachingFrame(Array(repeating: "回答", count: 65), intent: "full", action: "complete")))
    }

    func testReadsRealCompletionResponseFormat() async throws {
        let session = makeSession(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"先看目标：\\[P(A\\mid B)=P(A)\\]"}}]}"#)
        defer { session.invalidateAndCancel() }
        let answer = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key",
            messages: [ModelMessage(role: "user", content: "证明独立")], session: session)
        XCTAssertEqual(answer, #"先看目标：\[P(A\mid B)=P(A)\]"#)
    }

    func testStatusErrorsDoNotExposeRawResponseOrKey() async {
        for status in [401, 402, 404, 429, 500] {
            let session = makeSession(status: status, body: #"{"error":{"message":"test-key confidential server trace"}}"#)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: [], session: session)
                XCTFail("A failed response must not become a teaching message")
            } catch {
                XCTAssertTrue(error is ModelConnectionError)
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
                XCTAssertFalse(error.localizedDescription.contains("confidential"))
            }
        }
    }

    func testEmptyAndIncompatibleResponsesAreRejected() async {
        for body in [#"{"choices":[{"message":{"content":" "}}]}"#, #"{"reply":"wrong API"}"#, "<html>error</html>"] {
            let session = makeSession(status: 200, body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await ModelClient.complete(configuration: ModelConfiguration(), key: "test-key", messages: [], session: session)
                XCTFail("An empty or incompatible response must be rejected")
            } catch { XCTAssertTrue(error is ModelConnectionError) }
        }
    }

    func testPreferencesContainOnlyAddressAndModel() throws {
        let suite = "model-settings-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ModelConfiguration.load(from: defaults), ModelConfiguration())
        let configuration = ModelConfiguration(address: "https://provider.example/v1", model: "custom-model")
        configuration.save(to: defaults)
        XCTAssertEqual(ModelConfiguration.load(from: defaults), configuration)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys ?? Dictionary<String, Any>().keys), Set(["modelAddress", "modelName"]))
    }

    func testKeychainRestoresUpdatesAndIsolatesEndpoints() throws {
        let keychain = ModelKeychain(service: "com.studenthelper.yibu.tests." + UUID().uuidString)
        let first = ModelConfiguration(), second = ModelConfiguration(address: "https://provider.example/v1")
        defer { try? keychain.remove(for: first); try? keychain.remove(for: second) }
        XCTAssertEqual(try keychain.read(for: first), "")
        try keychain.save("first-test-key", for: first)
        XCTAssertEqual(try keychain.read(for: first), "first-test-key")
        XCTAssertEqual(try keychain.read(for: second), "")
        try keychain.save("second-test-key", for: second)
        try keychain.save("updated-test-key", for: first)
        XCTAssertEqual(try keychain.read(for: first), "updated-test-key")
        XCTAssertEqual(try keychain.read(for: second), "second-test-key")
        try keychain.remove(for: first)
        XCTAssertEqual(try keychain.read(for: first), "")
    }

    private func teachingMessages() -> [ModelMessage] {
        let history = [ModelMessage(role: "user", content: "旧题怎么做"),
                       ModelMessage(role: "assistant", content: "旧题的一步"),
                       ModelMessage(role: "user", content: "换一道题，只问前面的3如何处理")]
        return [ModelMessage(role: "system", content: ModelClient.instructions(for: history))] + history
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        } else { throw ModelConnectionError.response }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func teachingFrame(_ blocks: [String], intent: String = "local", action: String = "meaning",
                               focus: String = "当前疑问", prerequisite: String = "", prerequisiteReady: Bool = true) throws -> String {
        let object: [String: Any] = ["intent": intent, "action": action, "focus": focus,
                                     "prerequisite": prerequisite, "prerequisite_ready": prerequisiteReady, "blocks": blocks]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func completion(_ content: String, finish: String = "stop", reasoning: String = "") throws -> String {
        let object: [String: Any] = ["choices": [["finish_reason": finish,
                                                  "message": ["role": "assistant", "content": content, "reasoning_content": reasoning]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func makeSession(status: Int, body: String) -> URLSession {
        makeSession(responses: [StubResponse(status: status, body: body)])
    }

    private func makeSession(responses: [StubResponse]) -> URLSession {
        StubProtocol.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubResponse {
    let status: Int
    let body: String
    var error: Error? = nil
}

private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [StubResponse] = []
    private static var captured: [URLRequest] = []
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }
    static func reset(_ responses: [StubResponse]) {
        lock.lock(); defer { lock.unlock() }
        self.responses = responses; captured = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let fixture = Self.responses.isEmpty ? StubResponse(status: 500, body: "No queued fixture") : Self.responses.removeFirst()
        Self.lock.unlock()
        if let error = fixture.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["role"], "system")
        XCTAssertTrue(messages.first?["content"]?.contains(#"\[公式\]"#) == true)
        XCTAssertEqual(messages.last?["content"], "这一步不懂")
        let custom = try ModelClient.request(configuration: ModelConfiguration(address: "https://provider.example/v1", model: "custom-model"), key: "other-key", messages: [])
        let customBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(custom.httpBody)) as? [String: Any])
        XCTAssertNil(customBody["thinking"])
        XCTAssertEqual(customBody["model"] as? String, "custom-model")
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

    private func makeSession(status: Int, body: String) -> URLSession {
        StubProtocol.status = status; StubProtocol.body = Data(body.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

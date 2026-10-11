import Foundation
import SwiftUI
import Network
import Security
import Darwin
import CoreFoundation

struct AppMCPHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

enum AppMCPHTTPError: Error {
    case malformed, headerTooLarge, bodyTooLarge, unsupportedEncoding
    var status: Int {
        switch self {
        case .headerTooLarge: return 431
        case .bodyTooLarge: return 413
        default: return 400
        }
    }
}

/// One request per connection; reject ambiguous framing before parsing JSON.
struct AppMCPHTTPParser {
    static let maxHeaderBytes = 16 * 1024
    // Base64 expands an allowed 20 MB image by one third, plus JSON metadata.
    static let maxBodyBytes = 32 * 1024 * 1024
    private var buffer = Data()
    private(set) var headerRequest: AppMCPHTTPRequest?

    mutating func append(_ data: Data) throws -> AppMCPHTTPRequest? {
        guard buffer.count + data.count <= Self.maxHeaderBytes + Self.maxBodyBytes + 4 else { throw AppMCPHTTPError.bodyTooLarge }
        buffer.append(data)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes { throw AppMCPHTTPError.headerTooLarge }
            return nil
        }
        guard end.lowerBound <= Self.maxHeaderBytes else { throw AppMCPHTTPError.headerTooLarge }
        guard let text = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { throw AppMCPHTTPError.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw AppMCPHTTPError.malformed }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[2])),
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isUppercase }),
              parts[1].first == "/", !parts[1].contains("\r"), !parts[1].contains("\n") else { throw AppMCPHTTPError.malformed }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t", let colon = line.firstIndex(of: ":") else { throw AppMCPHTTPError.malformed }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ permitted.contains($0) }),
                  value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }), headers[name] == nil else { throw AppMCPHTTPError.malformed }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { throw AppMCPHTTPError.unsupportedEncoding }
        if parts[2] == "HTTP/1.1", headers["host"] == nil { throw AppMCPHTTPError.malformed }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0 >= "0" && $0 <= "9" }), let count = Int(raw) else { throw AppMCPHTTPError.malformed }
            guard count <= Self.maxBodyBytes else { throw AppMCPHTTPError.bodyTooLarge }
            length = count
        } else {
            guard parts[0] != "POST" else { throw AppMCPHTTPError.malformed }; length = 0
        }
        headerRequest = AppMCPHTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: Data())
        let bodyStart = end.upperBound
        guard buffer.count >= bodyStart + length else { return nil }
        guard buffer.count == bodyStart + length else { throw AppMCPHTTPError.malformed }
        return AppMCPHTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers,
                                 body: Data(buffer[bodyStart...]))
    }
}

enum AppMCPHTTPPolicy {
    static let versions = ["2025-06-18", "2025-03-26", "2025-11-25"]
    /// Origin checks are exact authorities, never suffix or substring matches.
    static func rejection(for request: AppMCPHTTPRequest, token: String, allowedOrigins: Set<String>, allowedHosts: Set<String>) -> Int? {
        guard let auth = request.headers["authorization"], constantEqual(auth, "Bearer " + token) else { return 401 }
        if let origin = request.headers["origin"], !allowedOrigins.contains(origin.lowercased()) { return 403 }
        guard let host = request.headers["host"], allowedHosts.contains(host.lowercased()) else { return 403 }
        if let version = request.headers["mcp-protocol-version"], !versions.contains(version) { return 400 }
        guard request.target == "/mcp" else { return 404 }
        guard request.method == "POST" else { return 405 }
        let type = request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { return 415 }
        let accepted = request.headers["accept"]?.lowercased().split(separator: ",").map {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        } ?? []
        guard accepted.contains("application/json") || accepted.contains("*/*") else { return 406 }
        return nil
    }
    static func constantEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Streamable HTTP with JSON responses and no SSE or stateful session ID.
/// The in-app client uses dispatch too, preserving JSON-RPC and tool schemas.
@MainActor
final class AppMCPServer: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var endpoint = ""
    @Published private(set) var token: String?
    @Published private(set) var error: String?
    private var listener: NWListener?
    private var generation = UUID()
    private var clients: [UUID: Client] = [:]
    private var activeOperation: Operation?
    private var notebooks: NotebookStore?
    private var learning: LearningStore?
    private var automation: AppAutomation?
    private var allowedOrigins = Set<String>()
    private var allowedHosts = Set<String>()
    private var minimumVisibleNanoseconds: UInt64 = 400_000_000

    @MainActor private final class Client {
        let connection: NWConnection
        var parser = AppMCPHTTPParser()
        var timeout: Task<Void, Never>?
        var responded = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private struct Operation {
        let id: UUID
        let requestKey: String
        let clientID: UUID
        let sessionID: UUID
        var task: Task<Void, Never>?
        var timeout: Task<Void, Never>?
    }

    func start(notebooks: NotebookStore, learning: LearningStore, automation: AppAutomation) {
        stop()
        self.notebooks = notebooks; self.learning = learning; self.automation = automation
        do {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServerError.random }
            token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            #if DEBUG
            // Cross-process UI tests supply their own fresh UUID credential.
            // The override is accepted only with an isolated notebook test ID.
            let arguments = ProcessInfo.processInfo.arguments
            if let testFlag = arguments.firstIndex(of: "--notebook-test-id"), arguments.indices.contains(testFlag + 1),
               UUID(uuidString: arguments[testFlag + 1]) != nil,
               let tokenFlag = arguments.firstIndex(of: "--mcp-test-token"), arguments.indices.contains(tokenFlag + 1),
               let testToken = UUID(uuidString: arguments[tokenFlag + 1]) {
                token = testToken.uuidString
                minimumVisibleNanoseconds = 3_000_000_000
            }
            #endif
            let host = Self.localIPv4() ?? "127.0.0.1"
            let parameters = NWParameters.tcp
            if host == "127.0.0.1" {
                parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
            }
            let service = try NWListener(using: parameters, on: .any)
            let run = UUID(); generation = run; listener = service; error = nil
            service.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    switch state {
                    case .ready:
                        guard let port = service.port else { self.fail("MCP 端口无法读取。"); return }
                        self.endpoint = "http://\(host):\(port.rawValue)/mcp"
                        self.allowedHosts = Set([host, "127.0.0.1", "localhost", "[::1]"].map { "\($0):\(port.rawValue)" })
                        self.allowedOrigins = Set(self.allowedHosts.map { "http://" + $0 })
                        self.enabled = true
                    case .failed: self.fail("MCP 服务无法启动，请检查本地网络权限后重试。")
                    default: break
                    }
                }
            }
            service.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == run, self.enabled else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            service.start(queue: .main)
        } catch { fail("MCP 服务无法启动，请稍后重试。") }
    }

    func stop() {
        generation = UUID()
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        cancelActiveOperation(clearImmediately: true)
        for id in Array(clients.keys) { close(id) }
        notebooks = nil; learning = nil; automation = nil
        enabled = false; endpoint = ""; token = nil; allowedHosts = []; allowedOrigins = []
        minimumVisibleNanoseconds = 400_000_000
    }
    private func fail(_ message: String) { stop(); error = message }

    private func accept(_ connection: NWConnection) {
        guard clients.count < 8 else { connection.cancel(); return }
        let id = UUID(), client = Client(connection); clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.close(id) } }
            if case .cancelled = state { Task { @MainActor in self?.close(id) } }
        }
        connection.start(queue: .main)
        deadline(id, seconds: 10)
        receive(id)
    }
    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, failure in
            Task { @MainActor in
                guard let self, let client = self.clients[id], !client.responded else { return }
                do {
                    if let data {
                        let request = try client.parser.append(data)
                        // Reject unauthenticated callers before accumulating an
                        // image-sized body in the app's memory.
                        if let header = client.parser.headerRequest, let token = self.token,
                           let status = AppMCPHTTPPolicy.rejection(for: header, token: token, allowedOrigins: self.allowedOrigins, allowedHosts: self.allowedHosts) {
                            self.respond(id, status: status); return
                        }
                        if let request {
                            client.timeout?.cancel(); self.handle(request, clientID: id); return
                        }
                    }
                    if complete || failure != nil { self.close(id) }
                    else { self.receive(id) }
                } catch let problem as AppMCPHTTPError { self.respond(id, status: problem.status) }
                catch { self.respond(id, status: 400) }
            }
        }
    }
    private func deadline(_ id: UUID, seconds: UInt64) {
        clients[id]?.timeout?.cancel()
        clients[id]?.timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self else { return }
            if self.activeOperation?.clientID == id { self.cancelActiveOperation() }
            self.respond(id, status: 408)
        }
    }

    private func handle(_ request: AppMCPHTTPRequest, clientID: UUID) {
        guard let token, let notebooks, let automation else { respond(clientID, status: 503); return }
        if let status = AppMCPHTTPPolicy.rejection(for: request, token: token, allowedOrigins: allowedOrigins, allowedHosts: allowedHosts) {
            respond(clientID, status: status); return
        }
        let object: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed]) as? [String: Any] else {
                respond(clientID, status: 400, json: Self.rpcError(id: NSNull(), code: -32600, message: "Invalid Request")); return
            }
            object = parsed
        } catch { respond(clientID, status: 400, json: Self.rpcError(id: NSNull(), code: -32700, message: "Parse error")); return }
        guard Self.validEnvelope(object) else {
            respond(clientID, status: 400, json: Self.rpcError(id: NSNull(), code: -32600, message: "Invalid Request")); return
        }
        if object["method"] as? String == "notifications/cancelled", object["id"] == nil {
            if let params = object["params"] as? [String: Any], let id = params["requestId"], let key = Self.requestKey(id), key == activeOperation?.requestKey {
                cancelActiveOperation()
            }
            respond(clientID, status: 202); return
        }
        let isTool = object["method"] as? String == "tools/call" && object["id"] != nil
        if isTool {
            guard activeOperation == nil else {
                respond(clientID, status: 409, json: Self.rpcError(id: object["id"] ?? NSNull(), code: -32000, message: "已有操作正在进行。")); return
            }
            // The user's stop button revokes the external connection permission;
            // a protocol cancellation only ends its matching individual call.
            guard let sessionID = automation.begin(cancel: { [weak self] in self?.stop() }) else {
                respond(clientID, status: 409, json: Self.rpcError(id: object["id"] ?? NSNull(), code: -32000, message: "已有操作正在进行。")); return
            }
            let operationID = UUID()
            activeOperation = Operation(id: operationID, requestKey: Self.requestKey(object["id"]!)!, clientID: clientID, sessionID: sessionID)
            let learning = self.learning
            var visibleDuration = minimumVisibleNanoseconds
            #if DEBUG
            if minimumVisibleNanoseconds > 400_000_000 {
                // Give the UI capture time to press Stop without slowing every setup action.
                let toolName = (object["params"] as? [String: Any])?["name"] as? String
                visibleDuration = toolName == "read_page" ? 10_000_000_000 : 400_000_000
            }
            #endif
            let work = Task { @MainActor [weak self] in
                defer {
                    automation.end(sessionID)
                    if self?.activeOperation?.id == operationID {
                        self?.activeOperation?.timeout?.cancel()
                        self?.activeOperation = nil
                    }
                }
                let result = await Self.dispatch(object, notebooks: notebooks, learning: learning, automation: automation)
                do {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: visibleDuration)
                    guard let self else { return }
                    self.respond(clientID, status: result == nil ? 202 : 200, json: result)
                } catch {
                    self?.respond(clientID, status: 200, json: Self.rpcError(id: object["id"] ?? NSNull(), code: -32800, message: "Request cancelled"))
                }
            }
            activeOperation?.task = work
            activeOperation?.timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                guard let self, self.activeOperation?.id == operationID else { return }
                self.cancelActiveOperation()
                self.respond(clientID, status: 408)
            }
        } else {
            deadline(clientID, seconds: 10)
            Task { @MainActor [weak self] in
                let result = await Self.dispatch(object, notebooks: notebooks, learning: self?.learning, automation: automation)
                self?.respond(clientID, status: result == nil ? 202 : 200, json: result)
            }
        }
    }

    private func cancelActiveOperation(clearImmediately: Bool = false) {
        guard let operation = activeOperation else { return }
        // Keep the slot until cancelled work finishes its cleanup, so a new call
        // cannot race the old call's cancellation handlers.
        if clearImmediately { activeOperation = nil }
        operation.timeout?.cancel()
        operation.task?.cancel()
        automation?.end(operation.sessionID)
    }
    private func respond(_ id: UUID, status: Int, json: [String: Any]? = nil) {
        guard let client = clients[id], !client.responded else { return }
        client.responded = true; client.timeout?.cancel()
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let phrase = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 503: "Service Unavailable"][status] ?? "Error"
        var header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if json != nil { header += "Content-Type: application/json\r\n" }
        if status == 401 { header += "WWW-Authenticate: Bearer\r\n" }
        if status == 405 { header += "Allow: POST\r\n" }
        var output = Data((header + "\r\n").utf8); output.append(body)
        client.connection.send(content: output, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel(); client.connection.cancel()
        // Disconnection itself does not cancel an MCP tool. Explicit cancelled
        // notifications, execution deadlines, and server stop do.
    }

    static func dispatch(_ request: [String: Any], notebooks: NotebookStore, learning: LearningStore?, automation: AppAutomation) async -> [String: Any]? {
        guard validEnvelope(request) else { return rpcError(id: NSNull(), code: -32600, message: "Invalid Request") }
        guard let method = request["method"] as? String else { return nil }
        guard let id = request["id"] else {
            if method == "notifications/cancelled" { automation.stop() }
            return Optional<[String: Any]>.none
        }
        let params = (request["params"] as? [String: Any]) ?? [String: Any]()
        switch method {
        case "initialize":
            guard let proposed = params["protocolVersion"] as? String else { return rpcError(id: id, code: -32602, message: "Invalid params") }
            let chosen = AppMCPHTTPPolicy.versions.contains(proposed) ? proposed : "2025-06-18"
            return rpcResult(id: id, value: ["protocolVersion": chosen, "capabilities": ["tools": ["listChanged": false]],
                                           "serverInfo": ["name": "一步", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0"]])
        case "ping": return rpcResult(id: id, value: [:])
        case "tools/list": return rpcResult(id: id, value: ["tools": AppAutomation.tools])
        case "tools/call":
            guard let name = params["name"] as? String, AppAutomation.tools.contains(where: { $0["name"] as? String == name }),
                  (params["arguments"] == nil || params["arguments"] is [String: Any]) else { return rpcError(id: id, code: -32602, message: "Invalid params") }
            do {
                try Task.checkCancellation()
                let arguments = (params["arguments"] as? [String: Any]) ?? [String: Any]()
                let content = try await automation.perform(name, args: arguments, notebooks: notebooks, learning: learning)
                try Task.checkCancellation()
                return rpcResult(id: id, value: ["content": content, "isError": false])
            } catch is CancellationError { return rpcError(id: id, code: -32800, message: "Request cancelled") }
            catch { return rpcResult(id: id, value: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]) }
        default: return rpcError(id: id, code: -32601, message: "Method not found")
        }
    }
    static func validEnvelope(_ request: [String: Any]) -> Bool {
        guard request["jsonrpc"] as? String == "2.0" else { return false }
        if let id = request["id"], requestKey(id) == nil { return false }
        if let method = request["method"] {
            guard let method = method as? String, !method.isEmpty, request["result"] == nil, request["error"] == nil else { return false }
            if let params = request["params"], !(params is [String: Any]) { return false }
            return true
        }
        return request["id"] != nil && ((request["result"] != nil) != (request["error"] != nil))
    }
    static func requestKey(_ id: Any) -> String? {
        if let string = id as? String { return "s:" + string }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           number.doubleValue.rounded() == number.doubleValue { return "n:" + number.stringValue }
        return nil
    }
    static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
    private static func rpcResult(id: Any, value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
    private enum ServerError: Error { case random }
    private static func localIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: interface.ifa_name).hasPrefix("en"), (interface.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let value = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var ipv4 = value, result = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ipv4, &result, socklen_t(INET_ADDRSTRLEN)) != nil { return String(cString: result) }
        }
        return nil
    }
}

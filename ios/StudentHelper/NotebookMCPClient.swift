import Foundation

/// The app uses a documented in-process MCP transport. The HTTP server uses the
/// same JSON-RPC dispatcher and tools; neither transport bypasses the document engine.
@MainActor
final class NotebookMCPClient {
    private let notebooks: NotebookStore
    private let learning: LearningStore?
    private let automation: AppAutomation
    private var nextID = 0
    private var initialized = false
    init(notebooks: NotebookStore, learning: LearningStore?, automation: AppAutomation) {
        self.notebooks = notebooks; self.learning = learning; self.automation = automation
    }
    func initialize() async throws {
        guard !initialized else { return }
        _ = try await request("initialize", params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "一步笔记助手", "version": "0.5.0"]])
        _ = await AppMCPServer.dispatch(["jsonrpc": "2.0", "method": "notifications/initialized"], notebooks: notebooks, learning: learning, automation: automation)
        _ = try await request("tools/list", params: [:])
        initialized = true
    }
    func call(_ name: String, args: [String: Any]) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        try await initialize()
        let result = try await request("tools/call", params: ["name": name, "arguments": args])
        guard let content = result["content"] as? [[String: Any]] else { throw NotebookAgentError.invalidTool }
        if result["isError"] as? Bool == true {
            throw NotebookMCPError.message(content.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        }
        try Task.checkCancellation()
        return content
    }
    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        guard let response = await AppMCPServer.dispatch(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params], notebooks: notebooks, learning: learning, automation: automation),
              (response["id"] as? Int) == nextID else { throw NotebookAgentError.invalidTool }
        if let error = response["error"] as? [String: Any] {
            throw NotebookMCPError.message(error["message"] as? String ?? "操作未执行。")
        }
        guard let result = response["result"] as? [String: Any] else { throw NotebookAgentError.invalidTool }
        return result
    }
}

enum NotebookMCPError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

import SwiftUI

@MainActor
final class LearningStore: ObservableObject {
    @Published var state: LearningState
    @Published var pending = Set<UUID>()
    @Published var storageError: String?
    @Published var notice: String?
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let fileURL: URL
    var current: LearningChat? { state.chats.first { $0.id == state.currentID } }
    var backend: String {
        get { UserDefaults.standard.string(forKey: "backendURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "backendURL"); objectWillChange.send() }
    }

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = folder.appendingPathComponent("learning-state.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(LearningState.self, from: data) {
            state = saved
        } else {
            var initial = LearningState()
            let example = Example.chat()
            initial.chats = [example]; initial.currentID = example.id
            state = initial
        }
        if !state.chats.contains(where: { $0.id == state.currentID }) { state.currentID = state.chats.first?.id }
        for index in state.chats.indices where state.chats[index].replyInProgress {
            state.chats[index].replyInProgress = false
            state.chats[index].failure = "上次回复已中断，可以重发。"
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch { storageError = "暂时无法保存，请检查设备空间。" }
    }
    func select(_ chat: LearningChat) { state.currentID = chat.id; state.selectedCourse = chat.course; save() }
    func newChat(course: String? = nil) {
        let chat = LearningChat(title: "新对话", course: course ?? state.selectedCourse)
        state.chats.insert(chat, at: 0); select(chat)
    }
    func addCourse(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if !state.courses.contains(clean) { state.courses.append(clean) }
        state.selectedCourse = clean; save()
    }
    func updateDraft(_ text: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == state.currentID }) else { return }
        state.chats[index].draft = text; save()
    }
    func attach(names: [String], toCourse: Bool) {
        if toCourse { state.files += names.map { CourseFile(name: $0, course: state.selectedCourse) } }
        else if let index = state.chats.firstIndex(where: { $0.id == state.currentID }) {
            state.chats[index].messages.append(LearningMessage(role: "user", text: "附件：" + names.joined(separator: "、")))
        }
        save()
    }
    func loadExample() { let chat = Example.chat(); state.chats.insert(chat, at: 0); select(chat) }
    func send(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let id = state.currentID, !pending.contains(id), let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        if state.chats[index].messages.isEmpty { state.chats[index].title = String(clean.prefix(22)) }
        guard pending.count < 3 else { notice = "先等一条回复完成。"; return }
        let questions = parseQuestions(clean)
        if !questions.isEmpty { state.chats[index].questionQueue = questions; state.chats[index].questionIndex = 0 }
        state.chats[index].messages.append(LearningMessage(role: questions.isEmpty ? "user" : "paper", text: clean)); state.chats[index].draft = ""; state.chats[index].waitingQuestion = false; save()
        await startReply(id)
    }
    func retry() async { if let id = state.currentID { await startReply(id) } }
    private func startReply(_ id: UUID) async {
        guard !pending.contains(id), pending.count < 3 else { return }
        pending.insert(id)
        let task = Task { await self.reply(id) }
        requests[id] = task
        await task.value
        requests[id] = nil
    }
    func stop() { if let id = state.currentID { requests[id]?.cancel() } }
    var canNext: Bool {
        guard let chat = current, let queue = chat.questionQueue else { return false }
        return queue.count > 1 && (chat.questionIndex ?? 0) < queue.count - 1
    }
    func nextQuestion() async {
        guard canNext, let index = state.chats.firstIndex(where: { $0.id == state.currentID }), !pending.contains(state.chats[index].id), let queue = state.chats[index].questionQueue else { return }
        let next = (state.chats[index].questionIndex ?? 0) + 1, id = state.chats[index].id
        state.chats[index].questionIndex = next
        state.chats[index].messages.append(LearningMessage(role: "divider", text: "第\(queue[next].number)题"))
        state.chats[index].messages.append(LearningMessage(role: "paper", text: queue[next].text))
        state.chats[index].waitingQuestion = false; save()
        await startReply(id)
    }
    private func parseQuestions(_ text: String) -> [QueuedProblem] {
        let source = text as NSString
        guard let regex = try? NSRegularExpression(pattern: #"^\s*(?:第\s*(\d+)\s*题\s*[：:、.．]?|(\d{1,3})[.．、)）])\s*"#, options: .anchorsMatchLines) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard matches.count > 1 else { return [] }
        let questions = matches.enumerated().map { index, match -> QueuedProblem in
            let numberRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            return QueuedProblem(number: Int(source.substring(with: numberRange)) ?? 0, text: source.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return questions.allSatisfy { question in question.text.count >= 8 && ["求", "证明", "计算", "设", "若", "已知", "试", "判断", "解", "积分", "极限"].contains { question.text.contains($0) } } ? questions : []
    }
    func record(for course: String? = nil) -> LearningChat? {
        state.chats.first { $0.course == (course ?? state.selectedCourse) && $0.messages.contains { $0.role == "paper" && $0.text == Example.question } }
    }
    func questions(in chat: LearningChat) -> [String] {
        chat.messages.filter { message in message.role == "user" && ["不会", "不懂", "没懂", "为什么", "怎么", "不知道", "所以就独立"].contains { message.text.contains($0) } }.map(\.text)
    }
    func setReview(_ id: UUID, draft: String? = nil, status: String? = nil) {
        guard let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        if let draft { state.chats[index].reviewDraft = draft }
        if let status { state.chats[index].reviewStatus = status }
        save()
    }
    func delete(_ id: UUID) {
        requests[id]?.cancel(); state.chats.removeAll { $0.id == id }
        if state.currentID == id { state.currentID = state.chats.first?.id }
        if state.chats.isEmpty { newChat() }
        save()
    }
    func clearChats() {
        requests.values.forEach { $0.cancel() }; requests.removeAll(); state.chats = []; newChat()
    }
    var dataSize: String { ByteCountFormatter.string(fromByteCount: Int64((try? JSONEncoder().encode(state).count) ?? 0), countStyle: .file) }
    func addFiles(_ urls: [URL], toCourse: Bool) {
        if toCourse {
            for url in urls {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                state.files.append(CourseFile(name: url.lastPathComponent, course: state.selectedCourse, size: size))
            }
        } else { attach(names: urls.map(\.lastPathComponent), toCourse: false) }
        save(); notice = "仅记录文件名，内容未读取。"
    }
    func validateBackend(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        if url.scheme == "https" { return url }
        guard url.scheme == "http" else { return nil }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        let privateIP = parts.count == 4 && parts.allSatisfy { (0...255).contains($0) } && (parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])))
        return privateIP || host.hasSuffix(".local") ? url : nil
    }
    private func reply(_ id: UUID) async {
        guard let index = state.chats.firstIndex(where: { $0.id == id }) else { pending.remove(id); return }
        state.chats[index].failure = nil; state.chats[index].replyInProgress = true; save()
        defer { pending.remove(id); if let index = state.chats.firstIndex(where: { $0.id == id }) { state.chats[index].replyInProgress = false }; save() }
        do {
            guard let url = validateBackend(backend) else { throw ChatError.configuration }
            let all = state.chats[index].messages.filter { ["user", "teacher", "paper"].contains($0.role) }
            var recent = Array(all.suffix(80))
            if let paper = all.last(where: { $0.role == "paper" }), !recent.contains(where: { $0.id == paper.id }) { recent.insert(paper, at: 0) }
            let payload = recent.map { ["role": $0.role == "teacher" ? "assistant" : "user", "content": $0.text] }
            var request = URLRequest(url: url.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"; request.timeoutInterval = 95; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["messages": payload])
            let (data, response) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(ChatReply.self, from: data)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let text = result.reply, !text.isEmpty else { throw ChatError.server(result.error ?? "暂时无法回复，请重试") }
            if let target = state.chats.firstIndex(where: { $0.id == id }) { state.chats[target].messages.append(LearningMessage(role: "teacher", text: text)) }
        } catch {
            if let target = state.chats.firstIndex(where: { $0.id == id }) {
                state.chats[target].failure = Task.isCancelled ? "已停止。" : (error as? ChatError)?.errorDescription ?? "连接失败，请重试。"
            }
        }
    }
}

private struct ChatReply: Decodable { let reply: String?; let error: String? }
private enum ChatError: LocalizedError {
    case configuration, server(String)
    var errorDescription: String? {
        switch self { case .configuration: return "先在设置里填写服务地址。"; case .server(let message): return message }
    }
}

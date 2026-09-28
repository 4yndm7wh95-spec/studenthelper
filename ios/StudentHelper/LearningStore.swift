import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class LearningStore: ObservableObject {
    @Published var state: LearningState
    @Published var pending = Set<UUID>()
    @Published var storageError: String?
    @Published var notice: String?
    @Published var importing = Set<AttachmentDestination>()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private let fileURL: URL
    let images: ImageRepository
    var current: LearningChat? { state.chats.first { $0.id == state.currentID } }
    var backend: String {
        get { UserDefaults.standard.string(forKey: "backendURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "backendURL"); objectWillChange.send() }
    }

    init(fileURL: URL? = nil) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = fileURL ?? folder.appendingPathComponent("learning-state.json")
        images = ImageRepository(folder: self.fileURL.deletingLastPathComponent().appendingPathComponent("image-assets", isDirectory: true))
        #if DEBUG
        let resetForUITest = fileURL == nil && ProcessInfo.processInfo.arguments.contains("--ui-tests-reset")
        #else
        let resetForUITest = false
        #endif
        if !resetForUITest, let data = try? Data(contentsOf: self.fileURL), let saved = try? JSONDecoder().decode(LearningState.self, from: data) {
            state = saved
        } else {
            var initial = LearningState()
            let chat = LearningChat(title: "新对话", course: initial.selectedCourse)
            initial.chats = [chat]; initial.currentID = chat.id
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
    private func collectImages() { if importing.isEmpty { images.removeUnreferenced(in: state) } }
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
    func deleteCourse(_ name: String) {
        guard state.courses.contains(name) else { return }
        let removed = state.chats.filter { $0.course == name }
        for chat in removed { requests[chat.id]?.cancel() }
        state.courses.removeAll { $0 == name }
        state.chats.removeAll { $0.course == name }
        state.files.removeAll { $0.course == name }
        state.subjects.removeValue(forKey: name); state.courseNotes.removeValue(forKey: name)
        if state.selectedCourse == name { state.selectedCourse = state.courses.first ?? "" }
        if !state.chats.contains(where: { $0.id == state.currentID }) {
            state.currentID = state.chats.first(where: { $0.course == state.selectedCourse })?.id ?? state.chats.first?.id
            if let current { state.selectedCourse = current.course }
        }
        if state.chats.isEmpty { newChat(course: state.selectedCourse) }
        save(); collectImages()
    }
    func renameChat(_ id: UUID, to title: String) {
        let clean = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !clean.isEmpty, let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        state.chats[index].title = clean; state.chats[index].titleEdited = true; save()
    }
    func updateDraft(_ text: String) {
        guard let index = state.chats.firstIndex(where: { $0.id == state.currentID }) else { return }
        state.chats[index].draft = text; save()
    }
    func send(_ text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = state.currentID, !pending.contains(id), !importing.contains(.chat(id)), let index = state.chats.firstIndex(where: { $0.id == id }) else { return }
        let attachments = state.chats[index].draftImages ?? []
        guard !clean.isEmpty || !attachments.isEmpty else { return }
        guard pending.count < 3 else { notice = "先等一条回复完成。"; return }
        if state.chats[index].messages.isEmpty && state.chats[index].titleEdited != true && ["新对话", "新会话"].contains(state.chats[index].title) {
            state.chats[index].title = clean.isEmpty ? "图片作业" : String(clean.prefix(22))
        }
        let questions = parseQuestions(clean)
        if !questions.isEmpty { state.chats[index].questionQueue = questions; state.chats[index].questionIndex = 0 }
        state.chats[index].messages.append(LearningMessage(role: questions.isEmpty || !attachments.isEmpty ? "user" : "paper", text: clean, images: attachments.isEmpty ? nil : attachments))
        state.chats[index].draft = ""; state.chats[index].draftImages = []; state.chats[index].waitingQuestion = false; save()
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
        save(); collectImages()
    }
    func clearChats() {
        requests.values.forEach { $0.cancel() }; requests.removeAll(); state.chats = []; newChat(); collectImages()
    }
    var dataSize: String { ByteCountFormatter.string(fromByteCount: Int64((try? JSONEncoder().encode(state).count) ?? 0), countStyle: .file) }
    func addFiles(_ urls: [URL], to destination: AttachmentDestination) async {
        guard !importing.contains(destination) else { return }
        importing.insert(destination); defer { importing.remove(destination); collectImages() }
        let repository = images
        for url in urls {
            do {
                let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                if case .course(let course) = destination, !isImage {
                    guard course.isEmpty || state.courses.contains(course) else { continue }
                    state.files.append(CourseFile(name: url.lastPathComponent, course: course)); save()
                    continue
                }
                try checkImageLimit(destination)
                let image = try await Task.detached(priority: .userInitiated) { try repository.importFile(url) }.value
                try keepImage(image, at: destination)
            } catch { notice = (error as? ImageImportError)?.errorDescription ?? "图片未添加，请重新选择。" }
        }
    }
    func addPhotos(_ items: [PhotosPickerItem], to destination: AttachmentDestination) async {
        guard !importing.contains(destination) else { return }
        importing.insert(destination); defer { importing.remove(destination); collectImages() }
        let repository = images
        for item in items {
            do {
                try checkImageLimit(destination)
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ImageImportError.unreadable }
                let image = try await Task.detached(priority: .userInitiated) { try repository.importData(data, name: "照片.jpg") }.value
                try keepImage(image, at: destination)
            } catch { notice = (error as? ImageImportError)?.errorDescription ?? "照片未添加，请检查网络后重试。" }
        }
    }
    private func checkImageLimit(_ destination: AttachmentDestination) throws {
        if case .chat(let id) = destination, let chat = state.chats.first(where: { $0.id == id }), (chat.draftImages ?? []).count >= 4 { throw ImageImportError.limit }
    }
    func keepImage(_ image: LearningImage, at destination: AttachmentDestination) throws {
        switch destination {
        case .chat(let id):
            guard let index = state.chats.firstIndex(where: { $0.id == id }) else { collectImages(); return }
            guard (state.chats[index].draftImages ?? []).count < 4 else { collectImages(); throw ImageImportError.limit }
            state.chats[index].draftImages = (state.chats[index].draftImages ?? []) + [image]
        case .course(let course):
            guard course.isEmpty || state.courses.contains(course) else { collectImages(); return }
            state.files.append(CourseFile(name: image.name, course: course, size: Int64(image.size), image: image))
        }
        save()
    }
    func removeDraftImage(_ image: LearningImage) {
        guard let index = state.chats.firstIndex(where: { $0.id == state.currentID }) else { return }
        state.chats[index].draftImages?.removeAll { $0.id == image.id }; save(); collectImages()
    }
    func removeFile(_ id: UUID) { state.files.removeAll { $0.id == id }; save(); collectImages() }
    func useFileImage(_ file: CourseFile) {
        guard let image = file.image else { return }
        if current?.course != file.course {
            if let chat = state.chats.first(where: { $0.course == file.course }) { select(chat) }
            else { newChat(course: file.course) }
        }
        guard let id = state.currentID, current?.draftImages?.contains(where: { $0.id == image.id }) != true else { return }
        do { try keepImage(image, at: .chat(id)) } catch { notice = error.localizedDescription }
    }
    func modelMessages(for chat: LearningChat) throws -> [ModelMessage] {
        let all = chat.messages.filter { ["user", "teacher", "paper"].contains($0.role) }
        var recent = Array(all.suffix(80))
        if let paper = all.last(where: { $0.role == "paper" }), !recent.contains(where: { $0.id == paper.id }) { recent.insert(paper, at: 0) }
        let included = Set(recent.filter { $0.role != "teacher" }.flatMap { $0.images ?? [] }.suffix(8).map(\.id))
        return try recent.map { message in
            let attachments = (message.images ?? []).filter { included.contains($0.id) && message.role != "teacher" }
            let text = attachments.isEmpty && !(message.images ?? []).isEmpty ? message.text + "\n较早的作业图片已超出本次图片上下文，若需要查看该图，请让学生重新发送。" : message.text
            return ModelMessage(role: message.role == "teacher" ? "assistant" : "user", text: text, imageURLs: try attachments.map { try images.encoded($0) })
        }
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
            let payload = try modelMessages(for: state.chats[index])
            let text: String
            if ModelConfiguration.mode == .direct {
                let configuration = ModelConfiguration.load()
                let key = try ModelKeychain().read(for: configuration)
                text = try await ModelClient.complete(configuration: configuration, key: key,
                    messages: [ModelMessage(role: "system", content: ModelClient.teachingPrompt)] + payload)
            } else {
                guard let url = validateBackend(backend) else { throw ChatError.configuration }
                var request = URLRequest(url: url.appendingPathComponent("api/chat"))
                request.httpMethod = "POST"; request.timeoutInterval = 95; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(ServiceRequest(messages: payload))
                let (data, response) = try await URLSession.shared.data(for: request)
                let result = try JSONDecoder().decode(ChatReply.self, from: data)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let reply = result.reply, !reply.isEmpty else { throw ChatError.server("暂时无法回复，请重试。") }
                text = reply
            }
            try Task.checkCancellation()
            if let target = state.chats.firstIndex(where: { $0.id == id }) { state.chats[target].messages.append(LearningMessage(role: "teacher", text: text)) }
        } catch {
            if let target = state.chats.firstIndex(where: { $0.id == id }) {
                state.chats[target].failure = Task.isCancelled ? "已停止。" : ((error as? ModelConnectionError)?.errorDescription ?? (error as? ImageImportError)?.errorDescription ?? (error as? ChatError)?.errorDescription ?? "连接失败，请重试。")
            }
        }
    }
}

private struct ChatReply: Decodable { let reply: String?; let error: String? }
private struct ServiceRequest: Encodable { let messages: [ModelMessage] }
private enum ChatError: LocalizedError {
    case configuration, server(String)
    var errorDescription: String? {
        switch self { case .configuration: return "先在设置里填写服务地址。"; case .server(let message): return message }
    }
}

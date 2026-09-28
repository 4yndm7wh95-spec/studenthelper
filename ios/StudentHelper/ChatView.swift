import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @FocusState private var inputFocused: Bool
    @State private var sessionsOpen = false
    @State private var importerOpen = false
    @State private var isNearBottom = true
    @State private var showNewReply = false
    private var draft: Binding<String> { Binding(get: { store.current?.draft ?? "" }, set: { store.updateDraft($0) }) }
    private var pending: Bool { store.current.map { store.pending.contains($0.id) } ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let chat = store.current, !chat.messages.isEmpty {
                    LazyVStack(spacing: 12) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message).id(message.id)
                                .transition(reduced ? .opacity : .offset(y: 12).combined(with: .opacity))
                        }
                        if pending { HStack { ThinkingRow(); Spacer() } }
                        if let failure = chat.failure {
                            HStack(alignment: .center) {
                                Text(failure).font(.footnote).foregroundStyle(.red)
                                Spacer()
                                Button { Task { await store.retry() } } label: { Label("重发", systemImage: "arrow.clockwise").font(.footnote).frame(minHeight: 44) }.disabled(pending)
                            }.padding(12).background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { isNearBottom = true; showNewReply = false }.onDisappear { isNearBottom = false }
                    }.padding(16).animation(Notebook.message(reduced), value: chat.messages.count)
                } else {
                    VStack(spacing: 12) {
                        EmptyNotebook(symbol: "pencil.line", title: "一次只走一小步", subtitle: "把题目发来，我们一句一句来。")
                        Button("打开题 24 示例") { store.loadExample() }.buttonStyle(NotebookButton(primary: false))
                    }.frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if showNewReply {
                    Button { withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) }; showNewReply = false } label: { Label("新回复", systemImage: "arrow.down").font(.footnote) }.buttonStyle(NotebookButton(primary: false)).padding(12)
                }
            }
            .onChange(of: store.current?.messages.count) { _, _ in
                if isNearBottom || inputFocused { withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) } } else { showNewReply = true }
            }
            .onChange(of: store.state.currentID) { _, _ in showNewReply = false; isNearBottom = true; proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: inputFocused) { _, focused in if focused { withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
        }
        .background(Notebook.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { inputFocused = false; sessionsOpen = true } label: { Image(systemName: "list.bullet.rectangle").frame(width: 44, height: 44) }.accessibilityLabel("会话") }
            ToolbarItem(placement: .principal) { Button { sessionsOpen = true } label: { HStack(spacing: 5) { Text(store.current?.title ?? "新对话").font(.subheadline.weight(.semibold)).lineLimit(1); Image(systemName: "chevron.down").font(.caption2) }.foregroundStyle(Notebook.ink) }.accessibilityLabel("选择会话") }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("设置") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(isPresented: $sessionsOpen) { SessionsView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationCornerRadius(20) }
        .fileImporter(isPresented: $importerOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in switch result { case .success(let urls): store.addFiles(urls, toCourse: false); case .failure: store.notice = "文件未添加。" } }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !(store.current?.messages.isEmpty ?? true) {
                HStack(spacing: 8) {
                    if store.canNext { Button { Task { await store.nextQuestion() } } label: { Label("下一题", systemImage: "plus.square") } }
                    Button { Task { await store.send("我没懂这一步，请只示范当前这一步。") } } label: { Label("我没懂", systemImage: "questionmark.bubble") }
                    Menu { Button { Task { await store.send("请给这道题的简洁完整答案。") } } label: { Label("看完整答案", systemImage: "eye") } } label: { Image(systemName: "ellipsis").frame(width: 44) }.accessibilityLabel("更多解题方式")
                }.font(.caption).buttonStyle(.bordered).tint(Notebook.secondary).frame(minHeight: 44).disabled(pending)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !(store.current?.course.isEmpty ?? true) { Button { inputFocused = false; importerOpen = true } label: { Image(systemName: "paperclip").frame(width: 44, height: 44) }.accessibilityLabel("添加作业") }
                TextField(store.current?.waitingQuestion == true ? "发下一道题…" : "说说你的想法…", text: draft, axis: .vertical).lineLimit(1...5).reading().padding(.horizontal, 12).padding(.vertical, 8).frame(minHeight: 44).background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(inputFocused ? Notebook.accent : Notebook.line, lineWidth: 1)).focused($inputFocused)
                Button { if pending { store.stop() } else { Task { await store.send(store.current?.draft ?? "") } } } label: { Image(systemName: pending ? "stop.circle.fill" : "arrow.up.circle.fill").font(.system(size: 36)).frame(width: 44, height: 44).contentTransition(reduced ? .opacity : .symbolEffect(.replace)) }
                    .disabled(!pending && (store.current?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)).accessibilityLabel(pending ? "停止" : "发送")
                    .animation(reduced ? .easeInOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.9), value: pending)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Notebook.paper).overlay(alignment: .top) { Rectangle().fill(Notebook.line).frame(height: 1) }
    }
}

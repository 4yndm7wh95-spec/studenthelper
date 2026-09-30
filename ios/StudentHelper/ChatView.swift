import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @FocusState private var inputFocused: Bool
    @State private var sessionsOpen = false
    @State private var stick = true              // 贴底跟随：只有用户手动下拉（往回看）才置 false，内容变高不会
    @State private var showNewReply = false
    @State private var renaming = false
    @State private var newTitle = ""
    private var draft: Binding<String> { Binding(get: { store.current?.draft ?? "" }, set: { store.updateDraft($0) }) }
    private var pending: Bool { store.current.map { store.pending.contains($0.id) } ?? false }
    private var importing: Bool { store.state.currentID.map { store.importing.contains(.chat($0)) } ?? false }
    private var hasDraft: Bool { !(store.current?.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) || !(store.current?.draftImages?.isEmpty ?? true) }
    private enum SendMode { case send, stop, skip }
    private var sendMode: SendMode { pending ? .stop : hasDraft ? .send : store.pacing ? .skip : .send }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let chat = store.current, !chat.messages.isEmpty {
                    LazyVStack(spacing: 20) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message, onGrow: { follow(proxy, animated: false, fresh: true) }).id(message.id)
                                .transition(reduced ? .opacity : .offset(y: 8).combined(with: .opacity))
                        }
                        if pending { ThinkingRow() }
                        if let failure = failureText(chat) {
                            HStack(spacing: 12) {
                                Text(failure).font(.system(size: 14))
                                Spacer()
                                Button { Task { await store.retry() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("重新回复").disabled(pending)
                            }.foregroundStyle(failure == "已停止" ? Notebook.secondary : Notebook.danger)
                                .padding(.leading, 14).padding(.trailing, 2).frame(minHeight: 44)
                                .background(failure == "已停止" ? Notebook.sunk : Notebook.dangerSoft, in: bubbleShape(userSide: false))
                                .accessibilityElement(children: .combine)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                            .onAppear { stick = true; showNewReply = false }
                    }.padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 16).animation(Notebook.message(reduced), value: chat.messages.count)
                } else {
                    VStack(spacing: 12) { EmptyNotebook(symbol: "pencil.line", title: "把题目发来") }.frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { if $0.translation.height > 6 { stick = false } })
            .overlay(alignment: .bottom) {
                if showNewReply {
                    Button { stick = true; showNewReply = false; withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Image(systemName: "arrow.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(Notebook.ink).frame(width: 40, height: 40)
                            .background(Notebook.surface, in: Circle()).overlay(Circle().stroke(Notebook.lineStrong, lineWidth: 1)).shadow(color: Color(red: 0.29, green: 0.2, blue: 0.08).opacity(0.10), radius: 12, y: 4)
                            .overlay(alignment: .topTrailing) { Circle().fill(Notebook.accent).frame(width: 9, height: 9).overlay(Circle().stroke(Notebook.surface, lineWidth: 2)).offset(x: -2, y: 2) }
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel("回到最新").padding(.bottom, 12).transition(.opacity)
                }
            }
            .onChange(of: store.current?.messages.count) { _, _ in follow(proxy, animated: true, fresh: true) }
            .onChange(of: pending) { _, _ in follow(proxy, animated: true, fresh: false) }
            .onChange(of: store.state.currentID) { _, _ in showNewReply = false; stick = true; store.pacing = false; proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: inputFocused) { _, focused in if focused { stick = true; withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) } } }
        }
        .background(Notebook.paper)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { inputFocused = false; sessionsOpen = true } label: { Image(systemName: "list.bullet.rectangle").frame(width: 44, height: 44) }.accessibilityLabel("会话") }
            ToolbarItem(placement: .principal) {
                Button { newTitle = store.current?.title ?? ""; renaming = true } label: {
                    HStack(spacing: 6) { Text(store.current?.title ?? "新对话").font(.system(size: 17, weight: .semibold)).lineLimit(1); Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(Notebook.tertiary) }
                        .foregroundStyle(Notebook.ink).frame(minHeight: 44)
                }.accessibilityLabel("修改会话名称").accessibilityValue(store.current?.title ?? "新对话")
            }
            ToolbarItem(placement: .topBarTrailing) { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("设置") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .sheet(isPresented: $sessionsOpen) { SessionsView().presentationDetents([.medium, .large]).presentationDragIndicator(.visible).presentationCornerRadius(20) }
        .alert("会话名称", isPresented: $renaming) {
            TextField("会话名称", text: $newTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { if let id = store.current?.id { store.renameChat(id, to: newTitle) } }.disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 网络失败/已停止；或上次请求没等到回复就被杀掉（最后一条是学生消息且没有在请求中）。
    private func failureText(_ chat: LearningChat) -> String? {
        if let f = chat.failure { return f }
        if !pending, let last = chat.messages.last, last.role == "user" || last.role == "paper" { return "回复没有完成" }
        return nil
    }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool, fresh: Bool) {
        if stick { if animated { withAnimation(Notebook.scroll(reduced)) { proxy.scrollTo("bottom", anchor: .bottom) } } else { proxy.scrollTo("bottom", anchor: .bottom) } }
        else if fresh { withAnimation(.linear(duration: 0.16)) { showNewReply = true } }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let images = store.current?.draftImages, !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(images) { image in
                            ImagePreviewButton(image: image).frame(width: 64, height: 64).background(Notebook.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous)).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Notebook.line, lineWidth: 1))
                                .overlay(alignment: .topTrailing) {
                                    Button { store.removeDraftImage(image) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Notebook.ink).frame(width: 24, height: 24).background(Notebook.surface, in: Circle()).overlay(Circle().stroke(Notebook.lineStrong, lineWidth: 1)).frame(width: 44, height: 44) }.offset(x: 14, y: -14).accessibilityLabel("移除图片：" + image.name)
                                }
                        }
                    }.padding(.top, 10).padding(.horizontal, 10).padding(.trailing, 8)
                }
            }
            if store.canNext {
                Button { Task { await store.nextQuestion() } } label: { Label("下一题", systemImage: "plus").font(.system(size: 14, weight: .medium)).padding(.horizontal, 14).frame(height: 44).background(Notebook.surface, in: Capsule()).overlay(Capsule().stroke(Notebook.lineStrong, lineWidth: 1)) }
                    .foregroundStyle(Notebook.ink).disabled(pending).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ImageImportButton()
                TextField(store.current?.waitingQuestion == true ? "发下一道题…" : "说说你的想法…", text: draft, axis: .vertical).lineLimit(1...5).reading().padding(.horizontal, 4).padding(.vertical, 10).frame(minHeight: 44).focused($inputFocused)
                sendButton
            }.padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 4)
                .background(Notebook.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(inputFocused ? Notebook.accent : Notebook.lineStrong, lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.04), radius: 8, y: 2)
                .animation(.linear(duration: 0.16), value: inputFocused)
        }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8).background(Notebook.paper)
    }

    private var sendButton: some View {
        let mode = sendMode
        let disabled = mode == .send && (!hasDraft || importing)
        return Button {
            switch mode {
            case .stop: store.stop()
            case .skip: store.skipPacing()
            case .send: Task { await store.send(store.current?.draft ?? "") }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(disabled ? Notebook.disabledBg : mode == .skip ? Notebook.soft : Notebook.accent).frame(width: 40, height: 40)
                Image(systemName: mode == .stop ? "stop.fill" : mode == .skip ? "chevron.forward.2" : "arrow.up")
                    .font(.system(size: mode == .stop ? 14 : 17, weight: .bold))
                    .foregroundStyle(disabled ? Notebook.disabledFg : mode == .skip ? Notebook.softInk : Notebook.onAccent)
                    .contentTransition(reduced ? .opacity : .symbolEffect(.replace))
            }.frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityLabel(mode == .stop ? "停止回复" : mode == .skip ? "跳过等待" : "发送")
        .animation(.linear(duration: reduced ? 0.01 : 0.12), value: mode == .stop)
    }
}

import SwiftUI

struct CoursePicker: View {
    @EnvironmentObject private var store: LearningStore
    var body: some View {
        Menu { ForEach(store.state.courses, id: \.self) { course in Button { store.state.selectedCourse = course; store.save() } label: { if course == store.state.selectedCourse { Label(course, systemImage: "checkmark") } else { Text(course) } } } } label: { Label(store.state.selectedCourse.isEmpty ? "选择课程" : store.state.selectedCourse, systemImage: "book.closed").font(.footnote).lineLimit(1).frame(minHeight: 44) }
    }
}

struct RecordsView: View {
    @EnvironmentObject private var store: LearningStore
    @Binding var tab: WorkspaceTab
    @State private var search = ""
    private var record: LearningChat? {
        guard let record = store.record() else { return nil }
        let text = Example.question + "条件概率 全概率公式 独立性 " + store.questions(in: record).joined()
        return search.isEmpty || text.localizedCaseInsensitiveContains(search) ? record : nil
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let record {
                    NavigationLink { RecordDetailView(id: record.id, tab: $tab) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("题 24").font(.footnote).foregroundStyle(Notebook.accent); Spacer(); Text("演示记录").font(.caption).foregroundStyle(Notebook.secondary) }
                            Text(Example.question).font(.system(size: 16, weight: .semibold)).foregroundStyle(Notebook.ink).lineLimit(2)
                            Text("4 步 · \(store.questions(in: record).count) 个疑问 · \(record.course)").font(.footnote).foregroundStyle(Notebook.secondary)
                        }.notebookCard()
                    }.buttonStyle(.plain)
                } else { EmptyNotebook(symbol: "tray", title: search.isEmpty ? "还没有记录" : "没有匹配的题目") }
            }.padding(16)
        }.background(Notebook.paper).navigationTitle("记录").searchable(text: $search, prompt: "搜索题目")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { CoursePicker() } }
    }
}

struct RecordDetailView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    let id: UUID
    @Binding var tab: WorkspaceTab
    @State private var answerOpen = false
    @State private var stepsOpen = true
    @State private var conceptsOpen = true
    @State private var questionsOpen = true
    @State private var historyOpen = false
    private var record: LearningChat? { store.state.chats.first { $0.id == id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Example.question).reading().textSelection(.enabled).notebookCard()
                Text("演示记录").font(.caption).foregroundStyle(Notebook.secondary)
                DisclosureGroup(isExpanded: $answerOpen) { Text(Example.answer).reading().textSelection(.enabled).padding(.top, 12) } label: { Label("显示答案", systemImage: "eye").foregroundStyle(Notebook.ink) }.notebookCard()
                DisclosureGroup("步骤", isExpanded: $stepsOpen) { Text(Example.steps).reading().padding(.top, 12) }.notebookCard()
                DisclosureGroup("知识点", isExpanded: $conceptsOpen) {
                    ViewThatFits(in: .horizontal) {
                        HStack { concept("条件概率"); concept("全概率公式"); concept("独立性") }
                        VStack(alignment: .leading) { concept("条件概率"); concept("全概率公式"); concept("独立性") }
                    }.padding(.top, 12)
                }.notebookCard()
                if let record {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("这次怎么学的").font(.headline)
                        Text("从独立性要证明的等式开始。" + (record.messages.contains { $0.role == "user" && $0.text.contains("0.3") } ? "\n回答了两种情况下概率都是 0.3 的问题。" : "") + (record.messages.contains { $0.role == "user" && $0.text.contains("理解了") } ? "\n对讲解作出了“理解了”的反馈。" : "")).reading()
                    }.notebookCard()
                    DisclosureGroup("我的疑问", isExpanded: $questionsOpen) {
                        let questions = store.questions(in: record)
                        if questions.isEmpty { Text("还没有追问记录。").font(.footnote).foregroundStyle(Notebook.secondary).padding(.top, 12) }
                        ForEach(Array(questions.enumerated()), id: \.offset) { _, question in HStack(alignment: .top, spacing: 12) { Rectangle().fill(Notebook.amber).frame(width: 3); Text("“\(question)”").reading(); Spacer(minLength: 0) }.fixedSize(horizontal: false, vertical: true).padding(.top, 12) }
                    }.notebookCard()
                    DisclosureGroup("全部聊天", isExpanded: $historyOpen) { LazyVStack(spacing: 12) { ForEach(record.messages) { MessageRow(message: $0) } }.padding(.top, 12) }.notebookCard()
                }
            }.padding(16).animation(Notebook.unfold(reduced), value: answerOpen).animation(Notebook.unfold(reduced), value: stepsOpen).animation(Notebook.unfold(reduced), value: conceptsOpen).animation(Notebook.unfold(reduced), value: questionsOpen).animation(Notebook.unfold(reduced), value: historyOpen)
        }.background(Notebook.paper).navigationTitle("题 24").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 12) {
                Button { store.setReview(id, status: "queued"); tab = .review } label: { Label("复习这题", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }.buttonStyle(NotebookButton())
                Button { if let record { store.select(record); tab = .chat } } label: { Label("回到聊天", systemImage: "bubble.left").frame(maxWidth: .infinity) }.buttonStyle(NotebookButton(primary: false))
            }.padding(16).background(Notebook.paper)
        }
    }
    private func concept(_ text: String) -> some View { Text(text).font(.footnote).padding(.horizontal, 10).padding(.vertical, 6).background(Notebook.soft, in: RoundedRectangle(cornerRadius: 8)) }
}

struct ReviewListView: View {
    @EnvironmentObject private var store: LearningStore
    private var records: [LearningChat] { store.state.chats.filter { $0.messages.contains { $0.text == Example.question } && ["queued", "again"].contains($0.reviewStatus ?? "") } }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if records.isEmpty { EmptyNotebook(symbol: "arrow.counterclockwise.circle", title: "暂无待复习", subtitle: "在记录里点“复习这题”。") }
                ForEach(records) { record in NavigationLink { ReviewExerciseView(id: record.id) } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text("题 24").font(.footnote).foregroundStyle(Notebook.accent); Spacer(); Text(record.reviewStatus == "again" ? "还不熟" : "待复习").font(.caption).foregroundStyle(Notebook.secondary) }; Text(Example.question).font(.body).foregroundStyle(Notebook.ink).lineLimit(2) }.notebookCard() }.buttonStyle(.plain) }
            }.padding(16)
        }.background(Notebook.paper).navigationTitle("复习")
    }
}

struct ReviewExerciseView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var draft = ""
    @State private var submitted = false
    @State private var answerOpen = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Example.question).reading().notebookCard()
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty { Text("不看提示，自己再做一遍").foregroundStyle(Notebook.secondary).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false) }
                    TextEditor(text: $draft).reading().scrollContentBackground(.hidden).frame(minHeight: 200).opacity(draft.isEmpty ? 0.7 : 1).accessibilityLabel("独立作答")
                }.notebookCard()
                if submitted {
                    DisclosureGroup("对照答案", isExpanded: $answerOpen) { Text(Example.answer).reading().textSelection(.enabled).padding(.top, 12) }.notebookCard().transition(reduced ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    if answerOpen { HStack { Button("会了") { store.setReview(id, draft: draft, status: "know"); dismiss() }.buttonStyle(NotebookButton()); Button("还不会") { store.setReview(id, draft: draft, status: "again"); dismiss() }.buttonStyle(NotebookButton(primary: false)) } }
                }
            }.padding(16)
        }.background(Notebook.paper).navigationTitle("重做题 24").navigationBarTitleDisplayMode(.inline).scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { if !submitted { Button("提交") { store.setReview(id, draft: draft); withAnimation(Notebook.scroll(reduced)) { submitted = true } }.buttonStyle(NotebookButton()).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).padding(16).frame(maxWidth: .infinity).background(Notebook.paper) } }
        .onAppear { draft = store.state.chats.first { $0.id == id }?.reviewDraft ?? "" }
        .onChange(of: draft) { _, value in store.setReview(id, draft: value) }
        .onDisappear { store.setReview(id, draft: draft) }
        .animation(Notebook.unfold(reduced), value: answerOpen)
    }
}

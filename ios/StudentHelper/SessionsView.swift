import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    @State private var ordinary = false
    @State private var newCourseOpen = false
    @State private var expanded = ""
    @State private var deleting: LearningChat?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("聊天分类", selection: $ordinary) { Text("课程").tag(false); Text("普通聊天").tag(true) }.pickerStyle(.segmented).padding(16)
                List {
                    if ordinary {
                        let chats = store.state.chats.filter { $0.course.isEmpty }
                        if chats.isEmpty { Text("还没有聊天").foregroundStyle(Notebook.secondary) }
                        ForEach(chats) { row($0) }
                    } else {
                        ForEach(store.state.courses, id: \.self) { course in
                            DisclosureGroup(isExpanded: Binding(get: { expanded == course }, set: { expanded = $0 ? course : "" })) {
                                let chats = store.state.chats.filter { $0.course == course }
                                ForEach(chats) { row($0) }
                                Button { store.state.selectedCourse = course; store.newChat(); dismiss() } label: { Label("新聊天", systemImage: "square.and.pencil").frame(minHeight: 44) }
                            } label: { Label(course, systemImage: "book.closed").font(.body.weight(.medium)).foregroundStyle(Notebook.ink).frame(minHeight: 44) }
                        }
                    }
                }.scrollContentBackground(.hidden).listStyle(.insetGrouped)
            }
            .background(Notebook.paper).navigationTitle("会话").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { newCourseOpen = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("新建课程") }
                ToolbarItem(placement: .topBarTrailing) { Button { store.newChat(course: ordinary ? "" : expanded.isEmpty ? store.state.courses.first ?? "" : expanded); dismiss() } label: { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }.accessibilityLabel("新聊天") }
            }
            .onAppear { expanded = store.state.selectedCourse; ordinary = store.state.selectedCourse.isEmpty }
            .sheet(isPresented: $newCourseOpen) { NewCourseView { expanded = $0 }.presentationDetents([.medium]).presentationDragIndicator(.visible).presentationCornerRadius(20) }
            .alert("删除这个聊天？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let deleting { store.delete(deleting.id) }; deleting = nil }
            } message: { Text("这个聊天的消息和草稿会一起删除。") }
        }
    }
    private func row(_ chat: LearningChat) -> some View {
        Button { store.select(chat); dismiss() } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chat.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(chat.id == store.state.currentID ? Notebook.accent : Notebook.ink).lineLimit(1)
                    Text(chat.draft.isEmpty ? chat.messages.last?.text ?? "发一道题开始" : "草稿 · " + chat.draft).font(.footnote).foregroundStyle(chat.draft.isEmpty ? Notebook.secondary : Notebook.amber).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.pending.contains(chat.id) { Circle().fill(Notebook.amber).frame(width: 8, height: 8).accessibilityLabel("回复中") }
                else if chat.id == store.state.currentID { Image(systemName: "checkmark").foregroundStyle(Notebook.accent) }
            }.frame(minHeight: 60)
        }.swipeActions { Button(role: .destructive) { deleting = chat } label: { Label("删除", systemImage: "trash") } }
    }
}

struct NewCourseView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    var created: (String) -> Void
    @State private var name = ""
    @State private var subject = "其他"
    @State private var note = ""
    @FocusState private var focus: Bool
    var body: some View {
        NavigationStack {
            Form {
                TextField("课程名称", text: $name).focused($focus).frame(minHeight: 48).onChange(of: name) { _, value in if value.count > 20 { name = String(value.prefix(20)) } }
                Picker("科目", selection: $subject) { ForEach(["高数", "线代", "概率", "大物", "C语言", "其他"], id: \.self) { Text($0).tag($0) } }.frame(minHeight: 48)
                TextField("备注（选填）", text: $note).frame(minHeight: 48)
            }.scrollContentBackground(.hidden).background(Notebook.paper)
            .navigationTitle("新建课程").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("创建") { let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); store.addCourse(clean); store.state.subjects[clean] = subject; store.state.courseNotes[clean] = note; store.save(); created(clean); dismiss() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear { focus = true }
        }
    }
}

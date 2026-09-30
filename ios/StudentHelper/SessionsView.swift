import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    @State private var ordinary = false
    @State private var newCourseOpen = false
    @State private var expanded = ""
    @State private var deleting: LearningChat?
    @State private var deletingCourse: String?
    @State private var renaming: LearningChat?
    @State private var title = ""
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
                        if store.state.courses.isEmpty {
                            Button { newCourseOpen = true } label: { Label("新建课程", systemImage: "plus").frame(minHeight: 44) }
                        }
                        ForEach(store.state.courses, id: \.self) { course in
                            DisclosureGroup(isExpanded: Binding(get: { expanded == course }, set: { expanded = $0 ? course : "" })) {
                                let chats = store.state.chats.filter { $0.course == course }
                                ForEach(chats) { row($0) }
                                Button { store.state.selectedCourse = course; store.newChat(); dismiss() } label: { Label("新聊天", systemImage: "square.and.pencil").frame(minHeight: 44) }
                            } label: {
                                HStack {
                                    Label(course, systemImage: "book.closed").font(.body.weight(.medium)).foregroundStyle(Notebook.ink)
                                    Spacer()
                                    Menu { Button(role: .destructive) { deletingCourse = course } label: { Label("删除课程", systemImage: "trash") } } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("管理课程：" + course)
                                }.frame(minHeight: 44)
                            }
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
            .sheet(isPresented: $newCourseOpen) { NewCourseView { expanded = $0; ordinary = false }.presentationDetents([.medium]).presentationDragIndicator(.visible).presentationCornerRadius(20) }
            .alert("删除这个聊天？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let deleting { store.delete(deleting.id) }; deleting = nil }
            } message: { Text("这个聊天的消息和草稿会一起删除。") }
            .alert("删除课程？", isPresented: Binding(get: { deletingCourse != nil }, set: { if !$0 { deletingCourse = nil } })) {
                Button("取消", role: .cancel) { deletingCourse = nil }
                Button("删除", role: .destructive) {
                    if let name = deletingCourse { store.deleteCourse(name); if expanded == name { expanded = store.state.selectedCourse } }
                    deletingCourse = nil
                }
            } message: { Text("“\(deletingCourse ?? "")”内的聊天和资料会一起删除。") }
            .alert("会话名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("会话名称", text: $title)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") { if let renaming { store.renameChat(renaming.id, to: title) }; renaming = nil }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func row(_ chat: LearningChat) -> some View {
        HStack(spacing: 0) {
            Button { store.select(chat); dismiss() } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chat.title).font(.system(size: 16, weight: chat.id == store.state.currentID ? .semibold : .regular)).foregroundStyle(Notebook.ink).lineLimit(1)
                        Text(chat.draft.isEmpty ? chat.messages.last?.text ?? "发一道题开始" : "草稿 · " + chat.draft).font(.footnote).foregroundStyle(chat.draft.isEmpty ? Notebook.tertiary : Notebook.amber).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if store.pending.contains(chat.id) { Circle().fill(Notebook.accent).frame(width: 8, height: 8).accessibilityLabel("回复中") }
                }.frame(minHeight: 60).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button { title = chat.title; renaming = chat } label: { Label("重命名", systemImage: "pencil") }
                Button(role: .destructive) { deleting = chat } label: { Label("删除", systemImage: "trash") }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Notebook.tertiary).frame(width: 44, height: 44) }.accessibilityLabel("管理聊天：" + chat.title)
        }
        .listRowBackground(chat.id == store.state.currentID ? Notebook.sunk : Notebook.surface)
        .swipeActions { Button(role: .destructive) { deleting = chat } label: { Label("删除", systemImage: "trash") } }
        .swipeActions(edge: .leading) { Button { title = chat.title; renaming = chat } label: { Label("重命名", systemImage: "pencil") }.tint(Notebook.accent) }
        .contextMenu {
            Button { title = chat.title; renaming = chat } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { deleting = chat } label: { Label("删除", systemImage: "trash") }
        }
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

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 笔记本沿用「一步」的纸面与文字层级；聊天继续使用原来的界面。
struct NotebooksView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var automation: AppAutomation
    @Environment(\.accessibilityReduceMotion) private var reduced
    var onAsk: ((UUID, UUID) -> Void)? = nil
    @State private var path: [UUID] = []
    @State private var search = ""
    @State private var creating = false
    @State private var settings = false
    @State private var renaming: NoteBookDocument?
    @State private var deleting: NoteBookDocument?
    @State private var title = ""
    @State private var recoveryConfirmation = false

    private var visibleBooks: [NoteBookDocument] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.notebooks }
        return store.notebooks.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.course.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if store.isStorageReadOnly { recoveryBanner }
                    if store.notebooks.isEmpty && !store.isStorageReadOnly {
                        emptyShelf
                    } else if visibleBooks.isEmpty {
                        EmptyNotebook(symbol: "magnifyingglass", title: "没有找到笔记本")
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 164, maximum: 244), spacing: 24)], alignment: .leading, spacing: 30) {
                            ForEach(visibleBooks) { book in
                                shelfBook(book)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Notebook.paper)
            .navigationTitle("笔记本")
            .searchable(text: $search, prompt: "查找笔记本或课程")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: {
                        Image(systemName: "gearshape").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("设置")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { creating = true } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("新建笔记本").accessibilityIdentifier("notebook-create").disabled(store.isStorageReadOnly)
                }
            }
            .navigationDestination(for: UUID.self) { notebookID in
                NotebookEditorView(notebookID: notebookID, onAsk: onAsk)
            }
            .sheet(isPresented: $creating) {
                NewNotebookSheet { notebookID in
                    search = ""
                    path.append(notebookID)
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).aiInteractionLocked()
            }
            .sheet(isPresented: $settings) { notebookSettingsSheet }
            .alert("笔记本名称", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("笔记本名称", text: $title)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let book = renaming { store.renameNotebook(book.id, title: title) }
                    renaming = nil
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("删除这本笔记？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) {
                    if let book = deleting { store.deleteNotebook(book.id) }
                    deleting = nil
                }
            } message: {
                Text("“\(deleting?.title ?? "")”中的所有页面、手写内容和图片都会从本机删除。")
            }
            .alert("备份损坏数据并重新开始？", isPresented: $recoveryConfirmation) {
                Button("取消", role: .cancel) {}
                Button("备份并重新开始", role: .destructive) { store.recoverStorage() }
            } message: {
                Text("现有数据会保留为备份，然后创建空的笔记本书架。你也可以先重新读取恢复后的文件。")
            }
        }
        .tint(Notebook.accent)
        .task {
            if automation.active || (automation.navigationRevision > 0 && automation.requestedNotebookID == store.currentNotebook?.id) { followAutomation() }
        }
        .onChange(of: automation.navigationRevision) { _, _ in followAutomation() }
        .animation(reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.38), value: path)
        .alert("无法保存笔记", isPresented: Binding(get: { store.storageError != nil && !store.isStorageReadOnly }, set: { if !$0 { store.storageError = nil } })) {
            Button("重试保存") { store.save() }
            Button("知道了", role: .cancel) { store.storageError = nil }
        } message: { Text(store.storageError ?? "") }
    }

    private func followAutomation() {
        let notebookID = automation.requestedNotebookID ?? automation.requestedPageID.flatMap { pageID in
            store.notebooks.first { $0.pages.contains { $0.id == pageID } }?.id
        }
        guard let notebookID, let book = store.notebook(id: notebookID) else { return }
        creating = false; settings = false; search = ""
        store.selectNotebook(notebookID)
        if let pageID = automation.requestedPageID, book.pages.contains(where: { $0.id == pageID }) { store.selectPage(pageID) }
        if path != [notebookID] { path = [notebookID] }
    }

    private var emptyShelf: some View {
        VStack(spacing: 22) {
            Image(systemName: "book.closed").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Notebook.accent)
            Text("新建笔记本").font(.subheadline).foregroundStyle(Notebook.secondary)
            Button { creating = true } label: { Image(systemName: "plus").frame(width: 20, height: 44) }
                .buttonStyle(NotebookButton()).accessibilityLabel("新建笔记本")
        }.frame(maxWidth: .infinity).padding(.vertical, 70)
    }

    private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("笔记数据需要恢复", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Notebook.amber)
            Text("原有文件已保留。恢复文件后重新读取，或先备份并创建新的书架。")
                .font(.footnote).foregroundStyle(Notebook.secondary)
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(Notebook.tertiary) }
            HStack {
                Button("重新读取") { store.retryLoad() }.buttonStyle(NotebookButton(primary: false))
                Button("备份并重新开始") { recoveryConfirmation = true }.buttonStyle(NotebookButton(primary: false))
            }
        }.notebookCard()
    }

    private var notebookSettingsSheet: some View {
        NavigationStack {
            SettingsView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } }
            }
        }.aiInteractionLocked()
    }

    private func shelfBook(_ book: NoteBookDocument) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                store.selectNotebook(book.id)
                path.append(book.id)
            } label: {
                NotebookCover(book: book)
            }.buttonStyle(NotebookIconMotion())
                .accessibilityLabel("打开笔记本：\(book.title)，\(book.pages.count) 页")
            HStack(spacing: 4) {
                Text("\(book.pages.count) 页").font(.caption).foregroundStyle(Notebook.tertiary)
                Spacer(minLength: 0)
                Menu {
                    Button { title = book.title; renaming = book } label: { Label("重命名", systemImage: "pencil") }
                    Button(role: .destructive) { deleting = book } label: { Label("删除笔记本", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(Notebook.tertiary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("管理笔记本：" + book.title).disabled(store.isStorageReadOnly)
            }.frame(height: 28)
        }
        .contextMenu {
            Button { title = book.title; renaming = book } label: { Label("重命名", systemImage: "pencil") }
            Button(role: .destructive) { deleting = book } label: { Label("删除笔记本", systemImage: "trash") }
        }
    }
}

private struct NotebookCover: View {
    let book: NoteBookDocument
    private var color: Color { notebookHexColor(book.coverColor) }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Notebook.surface)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.11))
            HStack(spacing: 0) {
                Rectangle().fill(color.opacity(0.7)).frame(width: 9)
                Rectangle().fill(color.opacity(0.15)).frame(width: 3)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                if !book.course.isEmpty {
                    Text(book.course).font(.caption).foregroundStyle(Notebook.secondary).lineLimit(1)
                }
                Text(book.title).font(.system(size: 21, weight: .medium)).foregroundStyle(Notebook.ink)
                    .lineLimit(4).multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Rectangle().fill(color.opacity(0.5)).frame(width: 32, height: 2)
                Text("一步").font(.caption).tracking(4).foregroundStyle(Notebook.tertiary)
            }.padding(.leading, 27).padding(.trailing, 20).padding(.vertical, 22)
        }
        .frame(height: 224)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Notebook.lineStrong.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.035), radius: 6, x: 1, y: 4)
        .accessibilityElement(children: .ignore)
    }
}

private struct NewNotebookSheet: View {
    @EnvironmentObject private var store: NotebookStore
    @Environment(\.dismiss) private var dismiss
    let onCreated: (UUID) -> Void
    @State private var title = ""
    @State private var course = ""
    @State private var paper = NotePaper.ruled
    @State private var cover = "#D97757"
    @FocusState private var titleFocused: Bool
    private let covers = ["#D97757", "#435B4A", "#566F87", "#77618C", "#B98D46", "#747069"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("笔记本名称", text: $title).focused($titleFocused).submitLabel(.next)
                        .accessibilityIdentifier("notebook-title")
                        .onChange(of: title) { _, value in if value.count > 60 { title = String(value.prefix(60)) } }
                    TextField("课程（选填）", text: $course)
                }
                Section("纸张") {
                    Picker("默认纸张", selection: $paper) {
                        ForEach(NotePaper.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("封面颜色") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(covers, id: \.self) { value in
                            Button { cover = value } label: {
                                Circle().fill(notebookHexColor(value)).frame(width: 30, height: 30)
                                    .overlay { if cover == value { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }.buttonStyle(NotebookIconMotion()).accessibilityLabel(notebookColorName(value))
                                .accessibilityAddTraits(cover == value ? .isSelected : [])
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Notebook.paper)
                .navigationTitle("新建笔记本").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            guard let notebookID = store.createNotebook(title: title.trimmingCharacters(in: .whitespacesAndNewlines), course: course.trimmingCharacters(in: .whitespacesAndNewlines), coverColor: cover) else { return }
                            if let first = store.currentNotebook?.pages.first { store.setPaper(paper, pageID: first.id) }
                            dismiss()
                            onCreated(notebookID)
                        }.accessibilityIdentifier("notebook-create-confirm")
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isStorageReadOnly)
                    }
                }
                .onAppear { titleFocused = true }
        }
    }
}

private struct NotebookEditorView: View {
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var automation: AppAutomation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduced
    let notebookID: UUID
    var onAsk: ((UUID, UUID) -> Void)?
    @State private var tool = NotebookDrawingTool.pen
    @State private var inkColor = Color(hex: 0x292724)
    @State private var penWidth: CGFloat = 3
    @State private var markerWidth: CGFloat = 20
    @State private var eraserWidth: CGFloat = 18
    @State private var fingerDrawing = false
    @State private var railOverride: Bool?
    @State private var undoTrigger = 0
    @State private var redoTrigger = 0
    @State private var pageTitle = ""
    @State private var titlePageID: UUID?
    @State private var titleDirty = false
    @State private var settings = false
    @State private var assistant = false
    @State private var assistantPageID: UUID?
    @State private var photo: PhotosPickerItem?
    @State private var photoImporter = false
    @State private var fileImporter = false
    @State private var importing = false
    @State private var importError: String?
    @State private var deletingPage: NotePage?
    @State private var renamingPage: NotePage?
    @State private var renamedPageTitle = ""
    @State private var renamingBook = false
    @State private var bookTitle = ""
    @State private var textEditor = false
    @State private var textDraft = ""
    @State private var editingTextID: UUID?
    @State private var textPageID: UUID?
    @FocusState private var pageTitleFocused: Bool
    @AppStorage("notebook.recentInkColors") private var recentColors = "292724,D97757,435B4A,566F87"

    private var book: NoteBookDocument? { store.notebooks.first { $0.id == notebookID } }
    private var page: NotePage? {
        guard let book else { return nil }
        return book.pages.first { $0.id == store.currentPage?.id } ?? book.pages.first
    }
    private var lineWidth: CGFloat {
        if tool == .highlighter { return markerWidth }
        if tool == .vectorEraser || tool == .pixelEraser { return eraserWidth }
        return penWidth
    }
    private var editableWidth: Binding<CGFloat> {
        Binding(get: { lineWidth }, set: { value in
            if tool == .highlighter { markerWidth = value }
            else if tool == .vectorEraser || tool == .pixelEraser { eraserWidth = value }
            else { penWidth = value }
        })
    }
    private var widthRange: ClosedRange<CGFloat> { tool == .highlighter ? 8...60 : tool == .vectorEraser || tool == .pixelEraser ? 8...80 : 1...20 }

    private var editorSurface: some View {
        GeometryReader { geometry in
            let expanded = railOverride ?? false
            ZStack(alignment: .top) {
                if let page {
                    pageCanvas(page).ignoresSafeArea(edges: .bottom)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))
                }
                else {
                    Button("添加页面") { addPage() }.buttonStyle(NotebookButton())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if expanded {
                    pagesRail(vertical: true).frame(width: 132)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .padding(.top, 64).padding(.bottom, 112)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                if page != nil {
                    NotebookToolDock { vertical in dockTools(vertical: vertical) }
                        .disabled(store.isStorageReadOnly)

                }
                if assistant, let assistantID = assistantPageID ?? page?.id, store.page(id: assistantID) != nil {
                    VStack { Spacer(minLength: 0); HStack { Spacer(minLength: 0)
                        NotebookChatPanel(available: CGSize(width: max(1, geometry.size.width - 24), height: max(1, geometry.size.height - 24)), viewport: geometry.frame(in: .global)) { panelSize, manualSize in
                            NotebookAssistantView(notebookID: notebookID, pageID: assistantID, availableHeight: manualSize ? panelSize.height : geometry.size.height * 0.75,
                                panelSize: manualSize ? panelSize : nil, onClose: { assistant = false })
                        }.id(assistantID)

                    } }.padding(12).transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
                }
            }.background(Notebook.paper).coordinateSpace(name: "notebook-window-space")
        }
    }

    private var editorNavigation: some View {
        editorSurface
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(book?.title ?? "笔记本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { finishTitleEditing(); dismissKeyboard(); railOverride = !(railOverride ?? false) } label: {
                    Label(page?.title ?? "页面", systemImage: "sidebar.left").font(.caption).lineLimit(1)
                }.accessibilityLabel((railOverride ?? false) ? "收起页面列表" : "展开页面列表")
                    .accessibilityIdentifier("page-browser")
                    .accessibilityValue("第 \(pageNumber) 页")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let page { paperMenu(page) }
                pageActions
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { bookTitle = book?.title ?? ""; renamingBook = true } label: { Label("笔记本名称", systemImage: "pencil") }
                    Button { settings = true } label: { Label("设置", systemImage: "gearshape") }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("笔记本选项")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { finishTitleEditing(); dismissKeyboard() }
            }
        }
        .task {
            store.selectNotebook(notebookID)
            titlePageID = page?.id
            pageTitle = page?.title ?? ""
        }
        .onChange(of: page?.id) { _, _ in
            if !automation.active { assistantPageID = page?.id }
            finishTitleEditing()
            pageTitleFocused = false
            titlePageID = page?.id
            pageTitle = page?.title ?? ""
        }
        .onChange(of: page?.title) { _, value in
            if !pageTitleFocused { titlePageID = page?.id; pageTitle = value ?? "" }
        }
        .onChange(of: pageTitleFocused) { _, focused in if !focused { finishTitleEditing() } }
        .onChange(of: book == nil) { _, missing in if missing { dismiss() } }
        .onChange(of: automation.active) { _, active in if active { finishTitleEditing(); dismissKeyboard() } }
        .onChange(of: automation.navigationRevision) { _, _ in
            if automation.active { settings = false; textEditor = false; photoImporter = false; fileImporter = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .notebookToolCommand)) { notification in
            receiveToolCommand(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .notebookFlushDrawing)) { _ in
            if titleDirty || pageTitleFocused { finishTitleEditing(); dismissKeyboard() }
        }
    }

    private var editorPresentation: some View {
        editorNavigation
        .photosPicker(isPresented: $photoImporter, selection: $photo, matching: .images)
        .onChange(of: photo) { _, selection in
            guard let selection, let pageID = page?.id else { return }
            Task { await importPhoto(selection, pageID: pageID) }
        }
        .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            guard let pageID = page?.id else { return }
            importFile(result, pageID: pageID)
        }
        .sheet(isPresented: $settings) {
            NavigationStack {
                SettingsView().toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } }
                }
            }.aiInteractionLocked()
        }
        .sheet(isPresented: $textEditor) {
            NotebookTextSheet(text: $textDraft, isNew: editingTextID == nil) {
                guard let pageID = textPageID else { return }
                if let objectID = editingTextID { store.updateText(textDraft, pageID: pageID, objectID: objectID) }
                else { _ = store.addText(textDraft, to: pageID) }
                tool = .lasso
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible).aiInteractionLocked()
        }
    }

    var body: some View {
        editorPresentation
        .buttonStyle(NotebookIconMotion())
        .alert("无法插入图片", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("知道了", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        .alert("删除这一页？", isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } })) {
            Button("取消", role: .cancel) { deletingPage = nil }
            Button("删除", role: .destructive) {
                if let page = deletingPage { store.deletePage(page.id) }
                deletingPage = nil
            }
        } message: { Text("这一页的手写内容、图片和文字都会删除。") }
        .alert("笔记本名称", isPresented: $renamingBook) {
            TextField("笔记本名称", text: $bookTitle)
            Button("取消", role: .cancel) {}
            Button("保存") { store.renameNotebook(notebookID, title: bookTitle) }
                .disabled(bookTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("页面名称", isPresented: Binding(get: { renamingPage != nil }, set: { if !$0 { renamingPage = nil } })) {
            TextField("页面名称", text: $renamedPageTitle)
            Button("取消", role: .cancel) { renamingPage = nil }
            Button("保存") {
                if let page = renamingPage { store.renamePage(page.id, title: renamedPageTitle) }
                renamingPage = nil
            }.disabled(renamedPageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onDisappear { finishTitleEditing() }
        .animation(reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: railOverride)
        .animation(reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.3), value: tool)
        .animation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.35), value: assistant)
        .animation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.4), value: page?.id)
    }

    private func receiveToolCommand(_ notification: Notification) {
        guard let info = notification.userInfo, let pageID = info["pageID"] as? UUID, pageID == page?.id else { return }
        if let raw = info["tool"] as? String, let value = NotebookDrawingTool(rawValue: raw) { tool = value == .vectorEraser ? .pixelEraser : value }
        if let hex = info["colorHex"] as? String { inkColor = notebookHexColor(hex) }
        if let width = info["width"] as? Double, width.isFinite {
            if tool == .highlighter { markerWidth = CGFloat(min(max(width, 8), 60)) }
            else if tool == .vectorEraser || tool == .pixelEraser { eraserWidth = CGFloat(min(max(width, 8), 80)) }
            else { penWidth = CGFloat(min(max(width, 1), 20)) }
        }
        if let enabled = info["allowsFingerDrawing"] as? Bool { fingerDrawing = enabled }
    }

    @ViewBuilder private func dockTools(vertical: Bool) -> some View {
        toolButton(.pen, symbol: "pencil.tip", title: "钢笔")
        toolButton(.highlighter, symbol: "highlighter", title: "荧光笔")
        toolButton(.pixelEraser, symbol: "eraser", title: "橡皮擦")
        toolButton(.lasso, symbol: "lasso", title: "套索")
        colorControl
        widthControl
        Button { finishTitleEditing(); dismissKeyboard(); undoTrigger += 1 } label: {
            Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("撤销").disabled(!store.canUndo)
        Button { finishTitleEditing(); dismissKeyboard(); redoTrigger += 1 } label: {
            Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("重做").disabled(!store.canRedo)

    }

    private var pageActions: some View {
        Group {
            if importing { ProgressView().accessibilityLabel("正在插入图片") }
            Menu {
                Button { finishTitleEditing(); dismissKeyboard(); photoImporter = true } label: { Label("从照片插入", systemImage: "photo") }
                Button { finishTitleEditing(); dismissKeyboard(); fileImporter = true } label: { Label("从文件插入图片", systemImage: "folder") }
            } label: { Image(systemName: "photo.badge.plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("插入图片").accessibilityIdentifier("notebook-import")
                .disabled(page == nil || importing || store.isStorageReadOnly)
            Button {
                finishTitleEditing(); dismissKeyboard()
                guard let pageID = page?.id else { return }
                if let onAsk { onAsk(notebookID, pageID) } else { assistantPageID = pageID; assistant = true }
            } label: {
                Image(systemName: "sparkles").font(.system(size: 20))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .foregroundStyle(Notebook.softInk).background(Notebook.soft, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(NotebookIconMotion()).disabled(page == nil || store.isStorageReadOnly)
                .accessibilityLabel("就这一页问一步").accessibilityIdentifier("ask-notebook")
        }
    }

    private var pageNumber: Int { (book?.pages.firstIndex { $0.id == page?.id } ?? 0) + 1 }

    private func swipePage(_ forward: Bool) {
        guard let pages = book?.pages, let page, let index = pages.firstIndex(where: { $0.id == page.id }) else { return }
        finishTitleEditing(); dismissKeyboard()
        withAnimation(reduced ? nil : .timingCurve(0.42, 0, 0.58, 1, duration: 0.38)) {
            if forward {
                if index + 1 < pages.count { store.selectPage(pages[index + 1].id) }
                else { addPage() }
            } else if index > 0 { store.selectPage(pages[index - 1].id) }
        }
    }

    private var toolbarDivider: some View { Rectangle().fill(Notebook.line).frame(width: 1, height: 26).padding(.horizontal, 4) }

    private func toolButton(_ value: NotebookDrawingTool, symbol: String, title: String) -> some View {
        Button {
            finishTitleEditing(); dismissKeyboard(); tool = value
        } label: {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Rectangle())
                .foregroundStyle(tool == value ? Notebook.accent : Notebook.secondary)
                .background(tool == value ? Notebook.soft : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel(title).accessibilityAddTraits(tool == value ? .isSelected : [])
    }

    private var colorControl: some View {
        NotebookInkPicker(color: $inkColor, recentColors: $recentColors)
            .disabled(tool == .vectorEraser || tool == .pixelEraser || tool == .lasso)
    }

    private var widthControl: some View {
        NotebookWidthPicker(width: editableWidth, range: widthRange)
            .disabled(tool == .lasso)
    }

    private func paperMenu(_ page: NotePage) -> some View {
        Menu {
            ForEach(NotePaper.allCases, id: \.self) { paper in
                Button { finishTitleEditing(); dismissKeyboard(); store.setPaper(paper, pageID: page.id) } label: {
                    Label(paper.title, systemImage: paper == page.paper ? "checkmark" : paperSymbol(paper))
                }
            }
            Divider()
            Button { addPage() } label: { Label("添加页面", systemImage: "plus") }
            Button(role: .destructive) { deletingPage = page } label: { Label("删除这一页", systemImage: "trash") }
        } label: {
            Image(systemName: paperSymbol(page.paper)).frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("纸张与页面选项，当前\(page.paper.title)").accessibilityIdentifier("paper-menu").disabled(store.isStorageReadOnly)
    }

    private func paperSymbol(_ paper: NotePaper) -> String {
        switch paper {
        case .blank: return "doc"
        case .ruled: return "text.alignleft"
        case .grid: return "square.grid.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }

    private func pageCanvas(_ page: NotePage) -> some View {
        NotebookCanvas(pageID: page.id, store: store, tool: tool, inkColor: inkColor, lineWidth: lineWidth,
                       allowsFingerDrawing: false, undoTrigger: undoTrigger, redoTrigger: redoTrigger,
                       onPageSwipe: swipePage, onUndoStateChange: { _, _ in }, onEditText: { objectID in beginTextEditing(objectID: objectID) })
            .id(page.id)
            .accessibilityLabel("\(pageDisplayTitle(page))的书写画布")
            .accessibilityIdentifier("notebook-canvas")
            .accessibilityValue("手写\(store.drawing(for: page.id).strokes.count)笔，图片\(page.objects.filter { $0.image != nil }.count)张")
    }

    private func pagesRail(vertical: Bool) -> some View {
        Group {
            if vertical {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array((book?.pages ?? []).enumerated()), id: \.element.id) { index, item in
                            pageButton(item, index: index, vertical: true)
                        }
                        addPageButton(vertical: true)
                    }.padding(16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(Array((book?.pages ?? []).enumerated()), id: \.element.id) { index, item in
                            pageButton(item, index: index, vertical: false)
                        }
                        addPageButton(vertical: false)
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }.frame(height: 150)
            }
        }.background(Notebook.side)
    }

    private func pageButton(_ item: NotePage, index: Int, vertical: Bool) -> some View {
        let selected = page?.id == item.id
        return Button {
            finishTitleEditing(); dismissKeyboard(); store.selectPage(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                NotePageThumbnail(page: item).aspectRatio(768.0 / 1086.0, contentMode: .fit)
                    .frame(width: vertical ? 116 : 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Notebook.accent : Notebook.lineStrong, lineWidth: selected ? 2 : 1))
                Text(thumbnailTitle(item, index: index))
                    .font(.caption2).foregroundStyle(selected ? Notebook.accent : Notebook.secondary)
                    .lineLimit(1).frame(width: vertical ? 116 : 76, alignment: .leading)
            }.padding(3)
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel("第 \(index + 1) 页，\(pageDisplayTitle(item))")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button { finishTitleEditing(); dismissKeyboard(); renamedPageTitle = item.title; renamingPage = item } label: { Label("重命名页面", systemImage: "pencil") }
                if index > 0 {
                    Button { store.reorderPages(notebookID: notebookID, fromOffsets: IndexSet(integer: index), toOffset: index - 1) } label: { Label("向前移动", systemImage: "arrow.up") }
                }
                if index < (book?.pages.count ?? 0) - 1 {
                    Button { store.reorderPages(notebookID: notebookID, fromOffsets: IndexSet(integer: index), toOffset: index + 2) } label: { Label("向后移动", systemImage: "arrow.down") }
                }
                Button(role: .destructive) { deletingPage = item } label: { Label("删除这一页", systemImage: "trash") }
            }
    }

    private func addPageButton(vertical: Bool) -> some View {
        Button { addPage() } label: {
            Image(systemName: "plus").font(.system(size: 21, weight: .light))
            .foregroundStyle(Notebook.tertiary).frame(width: vertical ? 116 : 76, height: vertical ? 112 : 102)
            .background(Notebook.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Notebook.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel("添加页面").accessibilityIdentifier("page-create").disabled(store.isStorageReadOnly)
    }

    private func thumbnailTitle(_ item: NotePage, index: Int) -> String {
        let automatic = item.title.range(of: "^第\\s*\\d+\\s*页$", options: .regularExpression) != nil
        return item.title.isEmpty || automatic ? "\(index + 1)" : "\(index + 1)  \(item.title)"
    }

    private func addPage() {
        finishTitleEditing(); dismissKeyboard()
        _ = store.createPage(notebookID: notebookID, paper: page?.paper ?? .ruled)
    }

    private func pageDisplayTitle(_ item: NotePage) -> String {
        if !item.title.isEmpty { return item.title }
        let position = (book?.pages.firstIndex { $0.id == item.id } ?? 0) + 1
        return "第 \(position) 页"
    }

    private func finishTitleEditing() {
        guard titleDirty else { return }
        defer { titleDirty = false }
        guard let pageID = titlePageID,
              let original = book?.pages.first(where: { $0.id == pageID }), original.title != pageTitle else { return }
        let clean = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { pageTitle = original.title; return }
        store.renamePage(pageID, title: clean)
    }

    private func beginTextEditing(objectID: UUID? = nil) {
        finishTitleEditing(); dismissKeyboard()
        guard let page else { return }
        textPageID = page.id
        editingTextID = objectID
        textDraft = objectID.flatMap { id in page.objects.first { $0.id == id }?.text } ?? ""
        textEditor = true
    }

    @MainActor private func importPhoto(_ selection: PhotosPickerItem, pageID: UUID) async {
        importing = true
        defer { importing = false; photo = nil }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self), UIImage(data: data) != nil else {
                importError = "这张图片无法读取。请换一张图片再试。"; return
            }
            if store.addImage(data: data, name: "照片", to: pageID) == nil {
                importError = store.storageError ?? "图片未能保存，请再试一次。"
            } else { tool = .lasso }
        } catch { importError = "未能读取照片：\(error.localizedDescription)" }
    }

    private func importFile(_ result: Result<[URL], Error>, pageID: UUID) {
        importing = true
        defer { importing = false }
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard UIImage(data: data) != nil else { importError = "请选择可以打开的图片文件。"; return }
            if store.addImage(data: data, name: url.lastPathComponent, to: pageID) == nil {
                importError = store.storageError ?? "图片未能保存，请再试一次。"
            } else { tool = .lasso }
        } catch { importError = "未能读取图片：\(error.localizedDescription)" }
    }

    private func dismissKeyboard() {
        pageTitleFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct NotePageThumbnail: View {
    @EnvironmentObject private var store: NotebookStore
    let page: NotePage
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(Color(hex: 0xFFFEFA)) }
        }
        .task(id: page.updatedAt) { image = NotePageRenderer.image(page: page, store: store, scale: 0.2) }
        .accessibilityHidden(true)
    }
}

private struct NotebookInkPicker: View {
    @Binding var color: Color
    @Binding var recentColors: String
    @State private var presented = false
    private let swatches: [(UInt32, String)] = [(0x292724, "墨黑"), (0xD97757, "陶土"), (0x435B4A, "松绿"), (0x566F87, "雾蓝"), (0x77618C, "灰紫"), (0xC59B36, "暖黄"), (0xC77589, "玫瑰"), (0xFFFFFF, "白色")]
    private var recent: [UInt32] { recentColors.split(separator: ",").compactMap { UInt32($0, radix: 16) }.prefix(8).map { $0 } }

    var body: some View {
        Button { presented = true } label: {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().stroke(Notebook.lineStrong, lineWidth: 1))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel("墨水颜色")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("墨水颜色").font(.subheadline.weight(.semibold)).foregroundStyle(Notebook.ink)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 8) {
                        ForEach(swatches, id: \.0) { value, name in swatch(value, name: name) }
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近使用").font(.caption).foregroundStyle(Notebook.tertiary)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 4), spacing: 8) {
                                ForEach(recent, id: \.self) { swatch($0, name: "最近使用的颜色") }
                            }
                        }
                    }
                    ColorPicker("自选颜色", selection: Binding(get: { color }, set: { value in color = value; remember(value) }), supportsOpacity: false)
                        .font(.subheadline).foregroundStyle(Notebook.ink)
                }.padding(22).frame(width: 248).background(Notebook.surface)
                    .presentationCompactAdaptation(.popover)
            }
    }

    private func swatch(_ value: UInt32, name: String) -> some View {
        let selected = colorHex(color) == value
        return Button {
            color = Color(hex: value); remember(color)
        } label: {
            Circle().fill(Color(hex: value)).frame(width: 28, height: 28)
                .overlay(Circle().stroke(Notebook.lineStrong, lineWidth: 1))
                .overlay { if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(value == 0xFFFFFF || value == 0xC59B36 ? .black : .white) } }
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func remember(_ color: Color) {
        let value = colorHex(color)
        let values = ([value] + recent.filter { $0 != value }).prefix(8)
        recentColors = values.map { String(format: "%06X", $0) }.joined(separator: ",")
    }

    private func colorHex(_ color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return UInt32((r * 255).rounded()) << 16 | UInt32((g * 255).rounded()) << 8 | UInt32((b * 255).rounded())
    }
}

private struct NotebookWidthPicker: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            VStack(spacing: 4) {
                Capsule().fill(Notebook.secondary).frame(width: 24, height: min(max(width / 2, 2), 10)).frame(height: 10)
                Text(String(format: "%.0f", width)).font(.caption2).monospacedDigit()
            }.frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(NotebookIconMotion()).accessibilityLabel("笔画粗细：\(Int(width))")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("笔画粗细").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f", width)).font(.caption).monospacedDigit().foregroundStyle(Notebook.tertiary)
                    }
                    Slider(value: $width, in: range, step: 0.5).tint(Notebook.accent).accessibilityLabel("笔画粗细")
                    HStack {
                        ForEach([range.lowerBound, (range.lowerBound + range.upperBound) / 2, range.upperBound], id: \.self) { value in
                            Button { width = value } label: {
                                Circle().fill(Notebook.ink).frame(width: min(value, 26), height: min(value, 26))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(abs(width - value) < 0.3 ? Notebook.soft : Notebook.paper, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(NotebookIconMotion()).accessibilityLabel("粗细 \(String(format: "%.1f", value))")
                        }
                    }
                }.foregroundStyle(Notebook.ink).padding(22).frame(width: 260).background(Notebook.surface)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

private struct NotebookTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let isNew: Bool
    let onSave: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.system(size: 18)).foregroundStyle(Notebook.ink)
                .scrollContentBackground(.hidden).padding(18).background(Notebook.paper).focused($focused)
                .accessibilityLabel("页面文字")
                .navigationTitle(isNew ? "插入文字" : "编辑文字").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isNew ? "插入" : "保存") { onSave(); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.onAppear { focused = true }
        }
    }
}

private func notebookHexColor(_ string: String) -> Color {
    Color(hex: UInt32(string.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xD97757)
}

private func notebookColorName(_ string: String) -> String {
    switch string {
    case "#D97757": return "陶土色封面"
    case "#435B4A": return "松绿色封面"
    case "#566F87": return "雾蓝色封面"
    case "#77618C": return "灰紫色封面"
    case "#B98D46": return "麦黄色封面"
    default: return "石灰色封面"
    }
}

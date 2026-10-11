import SwiftUI

@main
struct StudentHelperApp: App {
    @StateObject private var store = LearningStore()
    @StateObject private var notebooks = NotebookStore()
    var body: some Scene {
        WindowGroup { WorkspaceView().environmentObject(store).environmentObject(notebooks).tint(Notebook.accent) }
    }
}

enum WorkspaceTab: Hashable { case chat, records, files, review, notebooks }

struct WorkspaceView: View {
    @EnvironmentObject private var store: LearningStore
    @EnvironmentObject private var notebooks: NotebookStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var modelSettingsPreview = ProcessInfo.processInfo.arguments.contains("--model-settings-preview")
    #endif
    var body: some View {
        PadWorkspaceView()
        .overlay(alignment: .top) {
            if let text = store.notice {
                Text(text).font(.footnote).foregroundStyle(Notebook.ink).padding(14).background(Notebook.surface, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 10, y: 4).padding(16)
                    .transition(reduced ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduced ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0, 0, 1, duration: 0.24), value: store.notice)
        .onChange(of: store.notice) { _, value in
            guard let value else { return }
            Task { try? await Task.sleep(for: .seconds(2)); if store.notice == value { store.notice = nil } }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.save(); notebooks.save() } }
        .alert("无法保存", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) { Button("知道了", role: .cancel) { store.storageError = nil } } message: { Text(store.storageError ?? "") }
        #if DEBUG
        .fullScreenCover(isPresented: $modelSettingsPreview) { NavigationStack { SettingsView() }.environmentObject(store) }
        #endif
    }
}

private enum PadDestination: String, CaseIterable, Identifiable {
    case notebooks = "笔记本", chat = "教题", records = "记录", files = "文件", review = "复习", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .notebooks: return "book.closed"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .records: return "list.bullet.clipboard"
        case .files: return "folder"
        case .review: return "arrow.counterclockwise.circle"
        case .settings: return "gearshape"
        }
    }
}

struct PadWorkspaceView: View {
    @State private var destination: PadDestination? = .notebooks
    @State private var tab: WorkspaceTab = .chat
    var body: some View {
        NavigationSplitView {
            List(PadDestination.allCases, selection: $destination) { item in
                NavigationLink(value: item) { Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 7) }
            }
            .scrollContentBackground(.hidden).background(Notebook.side)
            .navigationTitle("一步").navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            switch destination ?? .notebooks {
            case .notebooks: NotebooksView()
            case .chat: NavigationStack { ChatView() }
            case .records: NavigationStack { RecordsView(tab: $tab) }
            case .files: NavigationStack { FilesView(tab: $tab) }
            case .review: NavigationStack { ReviewListView() }
            case .settings: NavigationStack { SettingsView() }
            }
        }
        .onChange(of: destination) { _, selected in
            switch selected {
            case .notebooks: tab = .notebooks
            case .records: tab = .records
            case .files: tab = .files
            case .review: tab = .review
            default: break
            }
        }
        .onChange(of: tab) { _, selected in if selected == .chat { destination = .chat } }
    }
}

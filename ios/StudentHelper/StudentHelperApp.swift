import SwiftUI

@main
struct StudentHelperApp: App {
    @StateObject private var store = LearningStore()
    var body: some Scene {
        WindowGroup { WorkspaceView().environmentObject(store).tint(Notebook.accent).preferredColorScheme(.light) }
    }
}

enum WorkspaceTab: Hashable { case chat, records, files, review }

struct WorkspaceView: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: WorkspaceTab = .chat
    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { ChatView() }.tabItem { Label("聊天", systemImage: "bubble.left.and.text.bubble.right") }.tag(WorkspaceTab.chat)
            NavigationStack { RecordsView(tab: $tab) }.tabItem { Label("记录", systemImage: "list.bullet.clipboard") }.tag(WorkspaceTab.records)
            NavigationStack { FilesView() }.tabItem { Label("文件", systemImage: "folder") }.tag(WorkspaceTab.files)
            NavigationStack { ReviewListView() }.tabItem { Label("复习", systemImage: "arrow.counterclockwise.circle") }.tag(WorkspaceTab.review)
        }
        .toolbarBackground(Notebook.side, for: .tabBar).toolbarBackground(.visible, for: .tabBar)
        .overlay(alignment: .top) {
            if let text = store.notice {
                Text(text).font(.footnote).foregroundStyle(Notebook.ink).padding(14).background(.white, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 10, y: 4).padding(16)
                    .transition(reduced ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduced ? .easeInOut(duration: 0.15) : .timingCurve(0.2, 0, 0, 1, duration: 0.24), value: store.notice)
        .onChange(of: store.notice) { _, value in
            guard let value else { return }
            Task { try? await Task.sleep(for: .seconds(2)); if store.notice == value { store.notice = nil } }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.save() } }
        .alert("无法保存", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) { Button("知道了", role: .cancel) { store.storageError = nil } } message: { Text(store.storageError ?? "") }
    }
}

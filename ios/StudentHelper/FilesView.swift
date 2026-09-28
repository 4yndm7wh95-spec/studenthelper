import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var store: LearningStore
    @Binding var tab: WorkspaceTab
    private var files: [CourseFile] { store.state.files.filter { $0.course == store.state.selectedCourse } }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CoursePicker().frame(maxWidth: .infinity, alignment: .leading)
                if files.isEmpty {
                    EmptyNotebook(symbol: "doc.badge.plus", title: "还没有文件")
                }
                ForEach(files) { file in
                    HStack(spacing: 16) {
                        if let image = file.image { ImagePreviewButton(image: image).frame(width: 76, height: 76) }
                        else { Image(systemName: "doc").font(.title2).foregroundStyle(Notebook.accent) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).font(.body).foregroundStyle(Notebook.ink)
                            Text(file.image == nil ? "仅保存文件名" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(Notebook.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            if file.image != nil { Button { store.useFileImage(file); tab = .chat } label: { Label("用这张图片做题", systemImage: "bubble.left") } }
                            Button(role: .destructive) { store.removeFile(file.id) } label: { Label("删除", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("管理资料：" + file.name)
                    }.notebookCard()
                }
            }.padding(16)
        }.background(Notebook.paper).navigationTitle("文件")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ImageImportButton(toCourse: true) } }
    }
}

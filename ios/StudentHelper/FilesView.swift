import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var store: LearningStore
    @State private var importerOpen = false
    private var files: [CourseFile] { store.state.files.filter { $0.course == store.state.selectedCourse } }
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                CoursePicker().frame(maxWidth: .infinity, alignment: .leading)
                if files.isEmpty {
                    EmptyNotebook(symbol: "doc.badge.plus", title: "还没有文件")
                    Button("添加文件") { importerOpen = true }.buttonStyle(NotebookButton())
                }
                ForEach(files) { file in
                    HStack(spacing: 16) {
                        Image(systemName: "doc").font(.title2).foregroundStyle(Notebook.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name).font(.body).foregroundStyle(Notebook.ink)
                            Text("\(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) · \(file.addedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(Notebook.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.notebookCard()
                }
                Text("目前只记录文件名，不识别内容。").font(.footnote).foregroundStyle(Notebook.secondary).padding(.top, 12)
            }.padding(16)
        }.background(Notebook.paper).navigationTitle("文件")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { importerOpen = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("添加文件") } }
        .fileImporter(isPresented: $importerOpen, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in switch result { case .success(let urls): store.addFiles(urls, toCourse: true); case .failure: store.notice = "文件未添加。" } }
    }
}

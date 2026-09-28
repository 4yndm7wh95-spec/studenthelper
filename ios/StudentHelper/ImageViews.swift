import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ImageImportButton: View {
    @EnvironmentObject private var store: LearningStore
    var toCourse = false
    @State private var filesOpen = false
    @State private var photosOpen = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var destination: AttachmentDestination?
    private var currentDestination: AttachmentDestination? {
        toCourse ? .course(store.state.selectedCourse) : store.state.currentID.map { .chat($0) }
    }
    private var busy: Bool { currentDestination.map { store.importing.contains($0) } ?? false }
    var body: some View {
        Menu {
            Button { destination = currentDestination; photosOpen = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
            Button { destination = currentDestination; filesOpen = true } label: { Label("从文件选择", systemImage: "folder") }
        } label: {
            Group { if busy { ProgressView() } else { Image(systemName: toCourse ? "plus" : "paperclip") } }.frame(width: 44, height: 44)
        }.disabled(busy || currentDestination == nil).accessibilityLabel(toCourse ? "添加资料" : "添加图片")
        .photosPicker(isPresented: $photosOpen, selection: $selectedPhotos, maxSelectionCount: toCourse ? 20 : 4, matching: .images, preferredItemEncoding: .current)
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty, let destination else { return }
            selectedPhotos = []
            Task { await store.addPhotos(items, to: destination) }
        }
        .fileImporter(isPresented: $filesOpen, allowedContentTypes: toCourse ? [.item] : [.image], allowsMultipleSelection: true) { result in
            guard let destination else { return }
            if case .success(let urls) = result { Task { await store.addFiles(urls, to: destination) } }
            else if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { store.notice = "文件未添加，请重新选择。" }
        }
    }
}

struct LearningImageView: View {
    @EnvironmentObject private var store: LearningStore
    let image: LearningImage
    var maxSize = 600
    @State private var thumbnail: UIImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
            else if loaded { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(Notebook.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.accessibilityLabel(image.name)
        .task(id: image.id) {
            let repository = store.images
            thumbnail = await Task.detached(priority: .userInitiated) { repository.thumbnail(image, maxSize: maxSize) }.value
            loaded = true
        }
    }
}

struct ImagePreviewButton: View {
    let image: LearningImage
    @State private var previewOpen = false
    var body: some View {
        Button { previewOpen = true } label: { LearningImageView(image: image).clipShape(RoundedRectangle(cornerRadius: 10)) }
            .buttonStyle(.plain).accessibilityLabel("查看图片：" + image.name)
            .fullScreenCover(isPresented: $previewOpen) { ImagePreview(image: image) }
    }
}

struct ImagePreview: View {
    @EnvironmentObject private var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    let image: LearningImage
    @State private var picture: UIImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let picture { ZoomableImage(picture: picture).ignoresSafeArea() }
            else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle()) }.padding(16).accessibilityLabel("关闭图片")
        }.task {
            let repository = store.images
            picture = await Task.detached(priority: .userInitiated) { repository.thumbnail(image, maxSize: 2560) }.value
            if picture == nil { dismiss(); store.notice = "图片已丢失，请重新添加。" }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let picture: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = ImageScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.backgroundColor = .black; scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        let image = scroll.pictureView; image.image = picture; image.contentMode = .scaleAspectFit
        scroll.addSubview(image); context.coordinator.image = image
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard scroll.zoomScale == 1 else { return }
        context.coordinator.image?.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var image: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: image), width = scroll.bounds.width / 2.5, height = scroll.bounds.height / 2.5
                scroll.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height), animated: true)
            }
        }
    }
    private final class ImageScrollView: UIScrollView {
        let pictureView = UIImageView()
        override func layoutSubviews() {
            super.layoutSubviews()
            if zoomScale == 1 { pictureView.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        }
    }
}

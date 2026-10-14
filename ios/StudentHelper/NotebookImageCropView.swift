import SwiftUI
import UIKit

struct NotebookImageCropTarget: Identifiable {
    let pageID: UUID
    let id: UUID
    let assetID: UUID
    let image: UIImage
}

struct NotebookImageCropView: View {
    let target: NotebookImageCropTarget
    let save: (CGRect) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var start: CGRect?
    @State private var dragging = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let available = CGSize(width: max(1, proxy.size.width - 64), height: max(1, proxy.size.height - 64))
                let scale = min(available.width / target.image.size.width, available.height / target.image.size.height)
                let size = CGSize(width: target.image.size.width * scale, height: target.image.size.height * scale)
                let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: target.image).resizable().frame(width: size.width, height: size.height)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect)
                    }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY).gesture(gesture(corner: nil, size: size))
                    Path { path in
                        path.addRect(rect)
                        for part in 1...2 {
                            let x = rect.minX + rect.width * CGFloat(part) / 3
                            let y = rect.minY + rect.height * CGFloat(part) / 3
                            path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                            path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                    }.stroke(.white.opacity(dragging ? 0.9 : 0.6), lineWidth: 1).allowsHitTesting(false)
                    ForEach(0..<4) { corner in
                        let left = corner % 2 == 0
                        let top = corner < 2
                        Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                            .scaleEffect(dragging ? 1.12 : 1)
                            .position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
                            .gesture(gesture(corner: corner, size: size))
                            .accessibilityLabel("裁剪角 \(corner + 1)").accessibilityIdentifier("image-crop-corner-\(corner)")
                    }
                }.frame(width: size.width, height: size.height).coordinateSpace(name: "photoCrop")
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }.background(Color.black.opacity(0.92))
                .navigationTitle("裁剪").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("取消裁剪")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { withAnimation(.easeInOut(duration: 0.32)) { crop = CGRect(x: 0, y: 0, width: 1, height: 1) } } label: { Image(systemName: "arrow.counterclockwise") }.accessibilityLabel("重置裁剪")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            if save(crop) { dismiss() } else { failed = true }
                        } label: { Image(systemName: "checkmark") }.accessibilityLabel("完成裁剪").accessibilityIdentifier("image-crop-confirm")
                    }
                }
                .alert("无法裁剪照片", isPresented: $failed) { Button("知道了", role: .cancel) {} }
        }.buttonStyle(NotebookIconMotion())
    }

    private func gesture(corner: Int?, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("photoCrop"))
            .onChanged { value in
                if start == nil {
                    start = crop
                    withAnimation(.easeInOut(duration: 0.22)) { dragging = true }
                }
                guard let initial = start else { return }
                let dx = value.translation.width / size.width, dy = value.translation.height / size.height
                if let corner {
                    let minW = min(0.2, 24 / size.width), minH = min(0.2, 24 / size.height)
                    let left = corner % 2 == 0, top = corner < 2
                    let x0 = left ? min(max(0, initial.minX + dx), initial.maxX - minW) : initial.minX
                    let x1 = left ? initial.maxX : max(min(1, initial.maxX + dx), initial.minX + minW)
                    let y0 = top ? min(max(0, initial.minY + dy), initial.maxY - minH) : initial.minY
                    let y1 = top ? initial.maxY : max(min(1, initial.maxY + dy), initial.minY + minH)
                    crop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                } else {
                    crop.origin = CGPoint(x: min(max(0, initial.minX + dx), 1 - initial.width), y: min(max(0, initial.minY + dy), 1 - initial.height))
                }
            }.onEnded { _ in
                start = nil
                withAnimation(.easeInOut(duration: 0.28)) { dragging = false }
            }
    }
}

import SwiftUI
import UIKit
import PencilKit

extension Notification.Name {
    /// Synchronous on the main actor: flush before AI reads or exports page content.
    static let notebookFlushDrawing = Notification.Name("NotebookFlushDrawing")
}

enum NotebookDrawingTool: String, CaseIterable, Identifiable {
    case pen, highlighter, vectorEraser, pixelEraser, lasso
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .highlighter: return "荧光笔"
        case .vectorEraser: return "整笔擦除"
        case .pixelEraser: return "局部擦除"
        case .lasso: return "套索"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .vectorEraser: return "eraser"
        case .pixelEraser: return "eraser.fill"
        case .lasso: return "lasso"
        }
    }
}

/// The page keeps native ink, image assets, and text objects in separate layers.
/// Only the surrounding viewport zooms; persisted geometry always uses page points.
@MainActor
struct NotebookCanvas: UIViewRepresentable {
    let pageID: UUID
    @ObservedObject var store: NotebookStore
    var tool: NotebookDrawingTool = .pen
    var inkColor: Color = Notebook.ink
    var lineWidth: CGFloat = 2.5
    var allowsFingerDrawing = false
    var undoTrigger = 0
    var redoTrigger = 0
    var onUndoStateChange: (Bool, Bool) -> Void = { _, _ in }
    var onEditText: (UUID) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> NotebookCanvasHost {
        let host = NotebookCanvasHost()
        context.coordinator.host = host
        host.scrollView.delegate = context.coordinator
        host.pageView.canvas.delegate = context.coordinator
        host.pageView.canvas.onUndo = { [weak coordinator = context.coordinator] in coordinator?.undo() }
        host.pageView.canvas.onRedo = { [weak coordinator = context.coordinator] in coordinator?.redo() }
        host.pageView.selection.onCommitFrame = { [weak coordinator = context.coordinator] objectID, rect in
            coordinator?.commitObjectFrame(objectID: objectID, rect: rect)
        }
        host.pageView.selection.onDelete = { [weak coordinator = context.coordinator] objectID in
            coordinator?.deleteObject(objectID)
        }
        host.pageView.selection.onEdit = { [weak coordinator = context.coordinator] objectID in
            coordinator?.editObject(objectID)
        }
        host.pageView.selection.onGestureBegan = { [weak coordinator = context.coordinator] in _ = coordinator?.flushDrawing() }
        host.pageView.selection.onPreviewFrame = { [weak host] objectID, rect in
            host?.pageView.previewFrame(rect, objectID: objectID)
        }
        context.coordinator.update(parent: self)
        return host
    }

    func updateUIView(_ uiView: NotebookCanvasHost, context: Context) {
        context.coordinator.update(parent: self)
    }

    static func dismantleUIView(_ uiView: NotebookCanvasHost, coordinator: Coordinator) {
        coordinator.stopAutomation()
        coordinator.flushDrawing()
        coordinator.endDrawingGroup()
        coordinator.pendingSave?.cancel()
        uiView.pageView.canvas.delegate = nil
        uiView.scrollView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: NotebookCanvas
        weak var host: NotebookCanvasHost?
        var loadedPageID: UUID?
        var loadedAsset: String?
        var loadedObjects: [UUID] = []
        var applyingDrawing = false
        var usingTool = false
        var drawingDirty = false
        var groupingDrawing = false
        var pendingSave: DispatchWorkItem?
        var lastUndoTrigger: Int
        var lastRedoTrigger: Int
        var lastUndoState: (Bool, Bool)?
        var backgroundObserver: NSObjectProtocol?
        var flushObserver: NSObjectProtocol?
        var commandObserver: NSObjectProtocol?
        var stopObserver: NSObjectProtocol?
        var viewportAnimator: UIViewPropertyAnimator?
        var pendingCommand: NotebookCanvasCommand?
        var automatedTool: (NotebookDrawingTool, UIColor, CGFloat, Bool?)?
        var previousParentTool: NotebookDrawingTool?
        var previousParentWidth: CGFloat?
        var previousParentColor: UIColor?
        var previousParentFinger: Bool?

        init(parent: NotebookCanvas) {
            self.parent = parent
            lastUndoTrigger = parent.undoTrigger
            lastRedoTrigger = parent.redoTrigger
            super.init()
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    _ = self?.flushDrawing()
                    self?.endDrawingGroup()
                }
            }
            flushObserver = NotificationCenter.default.addObserver(
                forName: .notebookFlushDrawing, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.flushDrawing() }
            }
            commandObserver = NotificationCenter.default.addObserver(forName: .notebookCanvasCommand, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let command = notification.object as? NotebookCanvasCommand else { return }
                    self?.handle(command)
                }
            }
            stopObserver = NotificationCenter.default.addObserver(forName: .notebookAutomationStopped, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopAutomation() }
            }
        }

        deinit {
            if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
            if let flushObserver { NotificationCenter.default.removeObserver(flushObserver) }
            if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
            if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        }

        func update(parent: NotebookCanvas) {
            let changedPage = loadedPageID != parent.pageID
            if changedPage {
                stopAutomation()
                flushDrawing()
                endDrawingGroup()
                usingTool = false
                // The store retains failed drafts by page; the incoming page gets
                // its own dirty state rather than overwriting the previous draft.
                drawingDirty = false
            }
            self.parent = parent
            guard let host, let page = parent.store.page(id: parent.pageID) else { return }
            let canvas = host.pageView.canvas
            if changedPage || (!drawingDirty && !usingTool && loadedAsset != page.drawingAsset) {
                applyingDrawing = true
                canvas.drawing = parent.store.drawing(for: page.id)
                applyingDrawing = false
                loadedAsset = page.drawingAsset
                if changedPage {
                    loadedPageID = page.id
                    loadedObjects = page.objects.map(\.id)
                    host.pageView.selection.select(nil)
                    host.resetPageViewport()
                }
            }
            host.setPageSize(page.size)
            host.pageView.update(page: page, store: parent.store)
            if !changedPage, let added = page.objects.last(where: { !loadedObjects.contains($0.id) }) {
                host.pageView.selection.select(added.id)
            }
            loadedObjects = page.objects.map(\.id)
            canvas.drawingPolicy = parent.allowsFingerDrawing ? .anyInput : .pencilOnly
            let color = UIColor(parent.inkColor).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
            if previousParentTool != parent.tool || previousParentWidth != parent.lineWidth || previousParentColor != color || previousParentFinger != parent.allowsFingerDrawing { automatedTool = nil }
            previousParentTool = parent.tool; previousParentWidth = parent.lineWidth; previousParentColor = color; previousParentFinger = parent.allowsFingerDrawing
            let settings = automatedTool ?? (parent.tool, color, parent.lineWidth, Optional(parent.allowsFingerDrawing))
            configureTool(settings.0, color: settings.1, width: settings.2, fingerDrawing: settings.3)
            // Object touch editing is explicit: Pencil keeps the native stroke lasso.
            host.pageView.selection.isUserInteractionEnabled = !usingTool && !parent.store.isStorageReadOnly
            canvas.isUserInteractionEnabled = !parent.store.isStorageReadOnly
            canvas.canUndoNotebook = parent.store.canUndo
            canvas.canRedoNotebook = parent.store.canRedo
            if parent.undoTrigger != lastUndoTrigger {
                lastUndoTrigger = parent.undoTrigger
                undo()
            }
            if parent.redoTrigger != lastRedoTrigger {
                lastRedoTrigger = parent.redoTrigger
                redo()
            }
            notifyUndoState()
        }

        func configureTool(_ tool: NotebookDrawingTool, color: UIColor, width: CGFloat, fingerDrawing: Bool?) {
            guard let host else { return }
            let canvas = host.pageView.canvas
            if let fingerDrawing { canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly }
            switch tool {
            case .pen:
                canvas.tool = PKInkingTool(.pen, color: color, width: max(1, min(20, width)))
            case .highlighter:
                canvas.tool = PKInkingTool(.marker, color: color, width: max(8, min(60, width)))
            case .vectorEraser:
                canvas.tool = PKEraserTool(.vector)
            case .pixelEraser:
                canvas.tool = PKEraserTool(.bitmap, width: max(8, min(80, width)))
            case .lasso:
                canvas.tool = PKLassoTool()
            }
            host.pageView.selection.allowsObjectSelection = tool == .lasso
        }

        func handle(_ command: NotebookCanvasCommand) {
            guard !command.accepted, command.pageID == loadedPageID, let host, host.window != nil else { return }
            command.accepted = true
            switch command.action {
            case .tool(let tool, let color, let width, let finger):
                automatedTool = (tool, color, width, finger)
                configureTool(tool, color: color, width: width, fingerDrawing: finger)
                command.result = ["page_id": command.pageID.uuidString, "tool": tool.rawValue, "width": width, "allows_finger_drawing": host.pageView.canvas.drawingPolicy == .anyInput]
            case .region(let rect):
                host.pageView.showOperationRegion(rect)
                command.result = ["page_id": command.pageID.uuidString]
            case .viewport(let x, let y, let dx, let dy, let zoom):
                viewportAnimator?.stopAnimation(true)
                pendingCommand?.failure = "后续操作替换了这次视口移动。"
                pendingCommand = command
                let scroll = host.scrollView
                let oldZoom = scroll.zoomScale
                let currentX = (scroll.contentOffset.x + scroll.contentInset.left) / oldZoom
                let currentY = (scroll.contentOffset.y + scroll.contentInset.top) / oldZoom
                let nextX = x ?? currentX + (dx ?? 0), nextY = y ?? currentY + (dy ?? 0)
                let changes = {
                    if let zoom { scroll.setZoomScale(max(scroll.minimumZoomScale, min(scroll.maximumZoomScale, zoom)), animated: false) }
                    host.centerPage()
                    let z = scroll.zoomScale
                    let maxX = max(-scroll.contentInset.left, scroll.contentSize.width - scroll.bounds.width + scroll.contentInset.right)
                    let maxY = max(-scroll.contentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom)
                    let offset = CGPoint(x: min(maxX, max(-scroll.contentInset.left, nextX * z - scroll.contentInset.left)),
                                         y: min(maxY, max(-scroll.contentInset.top, nextY * z - scroll.contentInset.top)))
                    scroll.contentOffset = offset
                }
                if UIAccessibility.isReduceMotionEnabled {
                    changes(); command.result = viewportState(); pendingCommand = nil
                } else {
                    let animator = UIViewPropertyAnimator(duration: 0.48, curve: .easeInOut, animations: changes)
                    animator.addCompletion { [weak self, weak command] position in
                        guard let self, let command else { return }
                        if position == .end { command.result = self.viewportState() }
                        else { command.failure = "视口操作已停止。" }
                        self.pendingCommand = nil; self.viewportAnimator = nil
                    }
                    viewportAnimator = animator
                    animator.startAnimation()
                }
            }
        }

        func viewportState() -> [String: Any] {
            guard let host, let pageID = loadedPageID else { return [:] }
            let visible = host.pageView.convert(host.scrollView.bounds, from: host.scrollView).intersection(host.pageView.bounds)
            return ["page_id": pageID.uuidString, "zoom": host.scrollView.zoomScale, "visible_rect": AppAutomation.rectDictionary(visible)]
        }

        func stopAutomation() {
            pendingCommand?.failure = "视口操作已停止。"
            if let viewportAnimator, viewportAnimator.state == .active {
                viewportAnimator.stopAnimation(false)
                viewportAnimator.finishAnimation(at: .current)
            }
            viewportAnimator = nil; pendingCommand = nil
            host?.pageView.showOperationRegion(nil)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // A preceding native lasso/menu edit may still be awaiting its
            // debounced save. Commit it before opening the next stroke's group.
            flushDrawing()
            usingTool = true
            host?.pageView.selection.isUserInteractionEnabled = false
            if !groupingDrawing {
                parent.store.beginUndoGroup()
                groupingDrawing = true
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applyingDrawing else { return }
            drawingDirty = true
            pendingSave?.cancel()
            // Native lasso menu actions can change ink outside a tool touch sequence.
            guard !usingTool else { return }
            let save = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { _ = self?.flushDrawing() }
            }
            pendingSave = save
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: save)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            usingTool = false
            flushDrawing()
            endDrawingGroup()
            host?.pageView.selection.isUserInteractionEnabled = !parent.store.isStorageReadOnly
            notifyUndoState()
        }

        @discardableResult
        func flushDrawing() -> Bool {
            pendingSave?.cancel()
            pendingSave = nil
            guard drawingDirty, !applyingDrawing, let pageID = loadedPageID, let canvas = host?.pageView.canvas else { return true }
            drawingDirty = false
            let saved = parent.store.updateDrawing(canvas.drawing, pageID: pageID)
            drawingDirty = !saved
            if saved { loadedAsset = parent.store.page(id: pageID)?.drawingAsset }
            notifyUndoState()
            return saved
        }

        func endDrawingGroup() {
            guard groupingDrawing else { return }
            parent.store.endUndoGroup()
            groupingDrawing = false
        }

        func undo() {
            guard flushDrawing() else { return }
            endDrawingGroup()
            parent.store.undo()
            reloadDrawing()
        }

        func redo() {
            guard flushDrawing() else { return }
            endDrawingGroup()
            parent.store.redo()
            reloadDrawing()
        }

        func reloadDrawing() {
            guard let pageID = loadedPageID, let host, let page = parent.store.page(id: pageID) else { return }
            applyingDrawing = true
            host.pageView.canvas.drawing = parent.store.drawing(for: pageID)
            applyingDrawing = false
            loadedAsset = page.drawingAsset
            host.pageView.update(page: page, store: parent.store)
            notifyUndoState()
        }

        func commitObjectFrame(objectID: UUID, rect: CGRect) {
            guard let pageID = loadedPageID else { return }
            if flushDrawing() {
                endDrawingGroup()
                _ = parent.store.updateObjectFrame(NoteRect(rect), pageID: pageID, objectID: objectID)
            }
            // Reconcile the preview even if disk storage rejected the edit.
            if let page = parent.store.page(id: pageID) { host?.pageView.update(page: page, store: parent.store) }
            notifyUndoState()
        }

        func deleteObject(_ objectID: UUID) {
            guard flushDrawing() else { return }
            endDrawingGroup()
            guard let pageID = loadedPageID else { return }
            host?.pageView.selection.select(nil)
            parent.store.removeObject(pageID: pageID, objectID: objectID)
            notifyUndoState()
        }

        func editObject(_ objectID: UUID) {
            flushDrawing()
            parent.onEditText(objectID)
        }

        func notifyUndoState() {
            let state = (parent.store.canUndo, parent.store.canRedo)
            guard lastUndoState?.0 != state.0 || lastUndoState?.1 != state.1 else { return }
            lastUndoState = state
            let callback = parent.onUndoStateChange
            DispatchQueue.main.async { callback(state.0, state.1) }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            guard scrollView === host?.scrollView else { return nil }
            return host?.pageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if scrollView === host?.scrollView { host?.centerPage() }
        }
    }
}

@MainActor
final class NotebookCanvasHost: UIView {
    let scrollView = UIScrollView()
    let pageView = NotebookPageSurface()
    private var pageSize = CGSize(width: 768, height: 1086)
    private var fittedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Notebook.sunk)
        scrollView.backgroundColor = backgroundColor
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 4
        scrollView.addSubview(pageView)
        addSubview(scrollView)
        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.08
        pageView.layer.shadowRadius = 12
        pageView.layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityLabel = "A4 笔记纸"
        accessibilityHint = "Apple Pencil 书写；双指移动或缩放。套索模式下用手指选中图片和文字。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        if fittedWidth == 0 {
            pageView.frame = CGRect(origin: .zero, size: pageSize)
            scrollView.contentSize = pageSize
            let fit = min(1, max(0.25, (bounds.width - 40) / pageSize.width))
            scrollView.minimumZoomScale = min(fit, 0.5)
            scrollView.setZoomScale(fit, animated: false)
            fittedWidth = bounds.width
            centerPage()
            scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
        } else {
            centerPage()
        }
    }

    func setPageSize(_ size: CGSize) {
        guard size != pageSize else { return }
        pageSize = size
        resetPageViewport()
    }

    func resetPageViewport() {
        fittedWidth = 0
        scrollView.setZoomScale(1, animated: false)
        pageView.frame = CGRect(origin: .zero, size: pageSize)
        pageView.setNeedsLayout()
        setNeedsLayout()
    }

    func centerPage() {
        let size = CGSize(width: pageSize.width * scrollView.zoomScale, height: pageSize.height * scrollView.zoomScale)
        let horizontal = max(20, (scrollView.bounds.width - size.width) / 2)
        let vertical = max(20, (scrollView.bounds.height - size.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}

/// Store history is the single undo source for both ink and editable page objects.
@MainActor
final class NotebookPKCanvasView: PKCanvasView {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var canUndoNotebook = false
    var canRedoNotebook = false
    override var undoManager: UndoManager? { nil }
    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoNotebook))
        undo.discoverabilityTitle = "撤销"
        let redo = UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoNotebook))
        redo.discoverabilityTitle = "重做"
        return [undo, redo]
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undoNotebook) { return canUndoNotebook }
        if action == #selector(redoNotebook) { return canRedoNotebook }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc private func undoNotebook(_ sender: UIKeyCommand) { onUndo?() }
    @objc private func redoNotebook(_ sender: UIKeyCommand) { onRedo?() }
}

@MainActor
final class NotebookPageSurface: UIView {
    let paper = NotebookPaperView()
    let objectLayer = UIView()
    let canvas = NotebookPKCanvasView()
    let selection = NotebookObjectSelection()
    private let operationHighlight = CAShapeLayer()
    private var objectViews: [UUID: UIView] = [:]
    private var objects: [NoteObject] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(paper)
        addSubview(objectLayer)
        addSubview(canvas)
        addSubview(selection)
        layer.addSublayer(operationHighlight)
        operationHighlight.fillColor = UIColor(Notebook.accent).withAlphaComponent(0.06).cgColor
        operationHighlight.strokeColor = UIColor(Notebook.accent).cgColor
        operationHighlight.lineWidth = 2
        operationHighlight.lineDashPattern = [6, 4]
        paper.isUserInteractionEnabled = false
        objectLayer.isUserInteractionEnabled = false
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.drawingPolicy = .pencilOnly
        canvas.clipsToBounds = true
        objectLayer.clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        paper.frame = bounds
        objectLayer.frame = bounds
        canvas.frame = bounds
        canvas.contentSize = bounds.size
        selection.frame = bounds
        selection.refreshSelection()
    }

    func update(page: NotePage, store: NotebookStore) {
        paper.paper = page.paper
        let ids = Set(page.objects.map(\.id))
        for id in Array(objectViews.keys) where !ids.contains(id) {
            objectViews.removeValue(forKey: id)?.removeFromSuperview()
        }
        for object in page.objects {
            let view: UIView
            switch object.content {
            case .image(let asset):
                let imageView = (objectViews[object.id] as? UIImageView) ?? UIImageView()
                imageView.image = store.image(for: asset)
                imageView.contentMode = .scaleToFill
                imageView.clipsToBounds = true
                view = imageView
            case .text(let text):
                let textView = (objectViews[object.id] as? NotebookTextObjectView) ?? NotebookTextObjectView()
                textView.value = text
                view = textView
            }
            if objectViews[object.id] !== view {
                objectViews[object.id]?.removeFromSuperview()
                objectViews[object.id] = view
                objectLayer.addSubview(view)
            }
            objectLayer.bringSubviewToFront(view)
            view.frame = object.frame.cgRect
        }
        objects = page.objects
        selection.update(objects: page.objects)
    }

    func previewFrame(_ frame: CGRect, objectID: UUID) { objectViews[objectID]?.frame = frame }

    func showOperationRegion(_ region: NoteRect?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        operationHighlight.path = region.map { UIBezierPath(roundedRect: $0.cgRect, cornerRadius: 8).cgPath }
        CATransaction.commit()
    }
}

@MainActor
final class NotebookPaperView: UIView {
    var paper: NotePaper = .blank { didSet { if oldValue != paper { setNeedsDisplay() } } }
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .white; isOpaque = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        NotebookPageRenderer.drawPaper(paper, in: bounds, context: context)
    }
}

@MainActor
final class NotebookTextObjectView: UIView {
    var value = NoteText(text: "") { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .clear; isOpaque = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) { NotebookPageRenderer.drawText(value, in: bounds) }
}

/// Interaction chrome never becomes part of the saved page or exported snapshot.
@MainActor
final class NotebookObjectSelection: UIView, UIGestureRecognizerDelegate {
    var allowsObjectSelection = false { didSet { refreshSelection() } }
    var onCommitFrame: ((UUID, CGRect) -> Void)?
    var onPreviewFrame: ((UUID, CGRect) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onGestureBegan: (() -> Void)?
    private var objects: [NoteObject] = []
    private var selectedID: UUID?
    private var previewRect: CGRect?
    private var startingRect: CGRect?
    private var resizing = false
    private let outline = CAShapeLayer()
    private let deleteButton = UIButton(type: .system)
    private let editButton = UIButton(type: .system)
    private let resizeHandle = UIView()
    private lazy var moveGesture = UIPanGestureRecognizer(target: self, action: #selector(panObject))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        outline.fillColor = UIColor.clear.cgColor
        outline.strokeColor = UIColor(Notebook.accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        outline.lineWidth = 2
        outline.lineDashPattern = [5, 3]
        layer.addSublayer(outline)
        configureButton(deleteButton, symbol: "xmark", label: "删除选中的内容", action: #selector(deleteSelected))
        configureButton(editButton, symbol: "pencil", label: "编辑选中的文字", action: #selector(editSelected))
        resizeHandle.backgroundColor = UIColor(Notebook.accent)
        resizeHandle.layer.cornerRadius = 7
        resizeHandle.layer.borderWidth = 2
        resizeHandle.layer.borderColor = UIColor.white.cgColor
        resizeHandle.accessibilityLabel = "拖动调整内容大小"
        addSubview(resizeHandle)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapObject))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.delegate = self
        addGestureRecognizer(tap)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapObject))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)
        moveGesture.maximumNumberOfTouches = 1
        moveGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        moveGesture.delegate = self
        addGestureRecognizer(moveGesture)
        refreshSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureButton(_ button: UIButton, symbol: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor(Notebook.accent)
        button.layer.cornerRadius = 16
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    func update(objects: [NoteObject]) {
        self.objects = objects
        if let selectedID, !objects.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if startingRect == nil { previewRect = nil }
        refreshSelection()
    }

    func select(_ id: UUID?) {
        selectedID = id
        previewRect = nil
        refreshSelection()
    }

    func refreshSelection() {
        guard allowsObjectSelection, let object = selectedObject else {
            outline.path = nil
            deleteButton.isHidden = true
            editButton.isHidden = true
            resizeHandle.isHidden = true
            return
        }
        let rect = previewRect ?? object.frame.cgRect
        outline.path = UIBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).cgPath
        deleteButton.isHidden = false
        resizeHandle.isHidden = false
        editButton.isHidden = object.text == nil
        deleteButton.frame = CGRect(x: min(max(0, rect.maxX - 16), max(0, bounds.width - 32)), y: max(0, rect.minY - 16), width: 32, height: 32)
        editButton.frame = CGRect(x: max(0, rect.minX - 16), y: max(0, rect.minY - 16), width: 32, height: 32)
        resizeHandle.frame = CGRect(x: min(max(0, rect.maxX - 14), max(0, bounds.width - 28)), y: min(max(0, rect.maxY - 14), max(0, bounds.height - 28)), width: 28, height: 28)
    }

    private var selectedObject: NoteObject? { objects.first(where: { $0.id == selectedID }) }
    private func object(at point: CGPoint) -> NoteObject? { objects.reversed().first(where: { $0.frame.cgRect.contains(point) }) }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, allowsObjectSelection, bounds.contains(point) else { return nil }
        if let touches = event?.allTouches, touches.contains(where: { $0.type == .pencil }) || touches.count > 1 { return nil }
        if !deleteButton.isHidden && deleteButton.frame.contains(point) { return deleteButton }
        if !editButton.isHidden && editButton.frame.contains(point) { return editButton }
        if !resizeHandle.isHidden && resizeHandle.frame.insetBy(dx: -10, dy: -10).contains(point) { return self }
        if object(at: point) != nil { return self }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIButton)
    }

    @objc private func tapObject(_ gesture: UITapGestureRecognizer) {
        select(object(at: gesture.location(in: self))?.id)
    }

    @objc private func doubleTapObject(_ gesture: UITapGestureRecognizer) {
        guard let object = object(at: gesture.location(in: self)) else { return }
        select(object.id)
        if object.text != nil { onEdit?(object.id) }
    }

    @objc private func deleteSelected() { if let selectedID { onDelete?(selectedID) } }
    @objc private func editSelected() { if let selectedID { onEdit?(selectedID) } }

    @objc private func panObject(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            resizing = selectedObject != nil && resizeHandle.frame.insetBy(dx: -10, dy: -10).contains(point)
            if !resizing, let object = object(at: point) { select(object.id) }
            guard let object = selectedObject else { return }
            onGestureBegan?()
            startingRect = object.frame.cgRect
            previewRect = startingRect
        case .changed:
            guard let object = selectedObject, let startingRect else { return }
            let translation = gesture.translation(in: self)
            let rect = adjusted(startingRect, translation: translation, preserveAspect: object.image != nil)
            previewRect = rect
            onPreviewFrame?(object.id, rect)
            refreshSelection()
        case .ended:
            guard let object = selectedObject, let startingRect else { return }
            let rect = adjusted(startingRect, translation: gesture.translation(in: self), preserveAspect: object.image != nil)
            self.startingRect = nil
            previewRect = nil
            onPreviewFrame?(object.id, rect)
            if rect != startingRect { onCommitFrame?(object.id, rect) }
            refreshSelection()
        case .cancelled, .failed:
            if let selectedID, let startingRect { onPreviewFrame?(selectedID, startingRect) }
            startingRect = nil
            previewRect = nil
            refreshSelection()
        default: break
        }
    }

    private func adjusted(_ original: CGRect, translation: CGPoint, preserveAspect: Bool) -> CGRect {
        if !resizing {
            return CGRect(x: min(max(0, original.minX + translation.x), max(0, bounds.width - original.width)),
                          y: min(max(0, original.minY + translation.y), max(0, bounds.height - original.height)),
                          width: original.width, height: original.height)
        }
        let maxWidth = max(24, bounds.width - original.minX)
        let maxHeight = max(24, bounds.height - original.minY)
        var width = min(maxWidth, max(48, original.width + translation.x))
        var height = min(maxHeight, max(48, original.height + translation.y))
        if preserveAspect {
            let ratio = max(0.01, original.width / max(1, original.height))
            width = min(width, maxHeight * ratio)
            height = width / ratio
        }
        return CGRect(x: original.minX, y: original.minY, width: width, height: height)
    }
}

@MainActor
enum NotebookPageRenderer {
    static func image(page: NotePage, store: NotebookStore, scale: CGFloat = 1) -> UIImage {
        NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
        let page = store.page(id: page.id) ?? page
        return render(page: page, drawing: store.drawing(for: page.id), store: store, scale: scale)
    }

    /// AI and export callers must surface an unreadable ink asset as an error.
    static func checkedImage(page: NotePage, store: NotebookStore, scale: CGFloat = 1) throws -> UIImage {
        NotificationCenter.default.post(name: .notebookFlushDrawing, object: nil)
        let page = store.page(id: page.id) ?? page
        for object in page.objects {
            if let asset = object.image, store.image(for: asset) == nil { throw NoteStorageError.invalidAsset }
        }
        return render(page: page, drawing: try store.drawingChecked(for: page.id), store: store, scale: scale)
    }

    private static func render(page: NotePage, drawing: PKDrawing, store: NotebookStore, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(0.25, min(3, scale))
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: page.size)
        return UIGraphicsImageRenderer(size: page.size, format: format).image { output in
            drawPaper(page.paper, in: bounds, context: output.cgContext)
            for object in page.objects {
                switch object.content {
                case .image(let asset): store.image(for: asset)?.draw(in: object.frame.cgRect)
                case .text(let text): drawText(text, in: object.frame.cgRect)
                }
            }
            drawing.image(from: bounds, scale: format.scale).draw(in: bounds)
        }
    }

    static func drawPaper(_ paper: NotePaper, in bounds: CGRect, context: CGContext) {
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)
        guard paper != .blank else { return }
        let line = UIColor(Notebook.line).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        context.setStrokeColor(line.cgColor)
        context.setFillColor(line.cgColor)
        context.setLineWidth(0.65)
        let inset: CGFloat = 40
        let spacing: CGFloat = paper == .ruled ? 28 : 24
        if paper == .dotted {
            for x in stride(from: inset, through: bounds.width - inset, by: spacing) {
                for y in stride(from: inset, through: bounds.height - inset, by: spacing) {
                    context.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                }
            }
        } else {
            for y in stride(from: inset, through: bounds.height - inset, by: spacing) {
                context.move(to: CGPoint(x: inset, y: y))
                context.addLine(to: CGPoint(x: bounds.width - inset, y: y))
            }
            if paper == .grid {
                for x in stride(from: inset, through: bounds.width - inset, by: spacing) {
                    context.move(to: CGPoint(x: x, y: inset))
                    context.addLine(to: CGPoint(x: x, y: bounds.height - inset))
                }
            }
            context.strokePath()
        }
    }

    static func drawText(_ text: NoteText, in rect: CGRect) {
        let value = text.colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let hex = UInt32(value, radix: 16) ?? 0x24262B
        let color = UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        (text.text as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: CGFloat(max(10, min(96, text.fontSize)))),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

typealias NotePageRenderer = NotebookPageRenderer

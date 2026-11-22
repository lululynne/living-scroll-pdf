import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The scroll view magnifies this view. Mouse positions, layer geometry and tile keys
/// always refer to pixels measured from the top left of the original screenshot.
final class EditCanvas: NSView, NSTextViewDelegate {
    private(set) var layers: [EditLayer]
    var tool: EditLayerKind? {
        didSet {
            guard tool != oldValue else { return }
            finishTextEditing()
            cancelDrag()
            if tool != nil { select(nil) }
            window?.invalidateCursorRects(for: self)
        }
    }
    var ink = InkColor.coral {
        didSet { if ink != oldValue, let textEditor { style(textEditor); onChange?() } }
    }
    var strokeWidth: CGFloat = 6
    var textSize: CGFloat = 28 {
        didSet { if textSize != oldValue, let textEditor { style(textEditor); onChange?() } }
    }
    var onChange: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var showsLayerSelection = true {
        didSet { invalidateOutline(selection) }
    }

    private var selectedID: UUID?
    var selection: EditLayer? { layers.first { $0.id == selectedID } }
    private let renderer: EditRenderer
    private let cache = NSCache<NSValue, CGImage>()

    private struct Change {
        let index: Int
        let before: EditLayer?
        let after: EditLayer?
    }
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private enum Drag {
        case drawing
        case moving(EditLayer)
        case resizing(EditLayer)

        var original: EditLayer? {
            switch self {
            case .drawing: return nil
            case .moving(let layer), .resizing(let layer): return layer
            }
        }
    }
    private var drag: Drag?
    private var start = CGPoint.zero
    private var preview: EditLayer?
    private var moved = false
    private var textEditor: CanvasTextView?
    private var editingLayer: EditLayer?
    private var typingID = UUID()
    private var textAnchor = CGPoint.zero

    init(original: CGImage, layers: [EditLayer], pointScale: Double = 1) {
        self.layers = layers
        renderer = EditRenderer(original: original, pointScale: pointScale)
        super.init(frame: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        cache.totalCostLimit = 64 << 20
        setAccessibilityLabel(L("长截图编辑画布", "Scrolling screenshot canvas"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func releaseRenderCaches() {
        cache.removeAllObjects()
        renderer.discardCachedImages()
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var zoom: CGFloat { max(0.001, enclosingScrollView?.magnification ?? 1) }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        switch tool {
        case nil, .image: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = dirtyRect.intersection(visibleRect).intersection(bounds)
        guard !visible.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill()
        visible.fill()

        // Only tiles touched by a live edit need a different composite. Keeping those
        // out of the cache makes cancelling a move or a text edit instantaneous.
        let previous = drag?.original ?? editingLayer
        var presented = layers
        if let previous, let index = presented.firstIndex(where: { $0.id == previous.id }) {
            if let preview { presented[index] = preview } else { presented.remove(at: index) }
        } else if let preview {
            presented.append(preview)
        }
        for rect in renderer.tiles(in: visible) where needsToDraw(rect) {
            let transient = previous?.paintBounds.intersects(rect) == true
                || preview?.paintBounds.intersects(rect) == true
            let key = NSValue(rect: rect)
            do {
                let image: CGImage
                if !transient, let cached = cache.object(forKey: key) {
                    image = cached
                } else {
                    image = try renderer.tile(rect, layers: transient ? presented : layers)
                    if !transient {
                        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
                    }
                }
                context.saveGState()
                context.setShouldAntialias(false)
                context.interpolationQuality = zoom >= 1 ? .none : .medium
                context.translateBy(x: rect.minX, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size))
                context.restoreGState()
            } catch {
                // A failed redaction must never expose the unedited tile as a fallback.
                let message = L("无法预览此图块", "Tile preview unavailable")
                (message as NSString).draw(in: rect.insetBy(dx: 5, dy: 5),
                                            withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
            }
        }
        if showsLayerSelection, textEditor == nil, let layer = drag?.original == nil ? selection : preview {
            drawSelection(layer)
        }
    }

    private func select(_ layer: EditLayer?) {
        invalidateOutline(selection)
        selectedID = layer?.id
        if let layer, layer.kind == .text {
            ink = layer.color
            textSize = layer.fontSize
        }
        invalidateOutline(layer)
        onSelectionChange?()
    }

    private func invalidateOutline(_ layer: EditLayer?) {
        guard let layer else { return }
        setNeedsDisplay(layer.paintBounds.insetBy(dx: -10 / zoom, dy: -10 / zoom))
    }

    private func invalidateTiles(of layer: EditLayer) {
        for tile in renderer.tiles(in: layer.paintBounds.intersection(bounds)) {
            cache.removeObject(forKey: NSValue(rect: tile))
            // A mosaic above this layer can change the rest of a sampled cell.
            setNeedsDisplay(tile)
        }
        invalidateOutline(layer)
    }

    private func handle(at rect: CGRect) -> CGRect {
        let side = 9 / zoom
        let visiblePart = rect.intersection(bounds)
        return CGRect(x: visiblePart.maxX - side, y: visiblePart.maxY - side, width: side, height: side)
    }

    private func drawSelection(_ layer: EditLayer) {
        let outline = NSBezierPath(rect: layer.paintBounds.insetBy(dx: -2 / zoom, dy: -2 / zoom))
        outline.lineWidth = 2 / zoom
        NSColor.white.withAlphaComponent(0.9).setStroke()
        outline.stroke()
        outline.lineWidth = 1 / zoom
        outline.setLineDash([4 / zoom, 3 / zoom], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        if layer.kind == .image {
            let knob = NSBezierPath(rect: handle(at: layer.rect))
            knob.lineWidth = 1 / zoom
            NSColor.controlAccentColor.setFill()
            knob.fill()
            NSColor.white.setStroke()
            knob.stroke()
        }
    }

    private func apply(_ change: Change, forward: Bool) {
        let old = forward ? change.before : change.after
        let new = forward ? change.after : change.before
        invalidateOutline(selection)
        if let old { invalidateTiles(of: old) }
        if old != nil { layers.remove(at: change.index) }
        if let new {
            layers.insert(new, at: change.index)
            invalidateTiles(of: new)
        }
        select(new)
        onChange?()
    }

    private func commit(before: EditLayer?, after: EditLayer?) {
        let index: Int
        if let before {
            guard let existing = layers.firstIndex(where: { $0.id == before.id }) else { return }
            index = existing
        } else {
            index = layers.count
        }
        let change = Change(index: index, before: before, after: after)
        undoStack.append(change)
        redoStack.removeAll()
        apply(change, forward: true)
    }

    func undoEdit() {
        finishTextEditing()
        cancelDrag()
        guard let change = undoStack.popLast() else { return }
        redoStack.append(change)
        apply(change, forward: false)
    }

    func redoEdit() {
        finishTextEditing()
        cancelDrag()
        guard let change = redoStack.popLast() else { return }
        undoStack.append(change)
        apply(change, forward: true)
    }

    func deleteSelection() {
        finishTextEditing()
        cancelDrag()
        if let selected = selection { commit(before: selected, after: nil) }
    }

    func applyStyleToSelection() {
        guard tool == nil || tool == .text else { return }
        guard textEditor == nil, var updated = selection else { return }
        let old = updated
        switch updated.kind {
        case .image, .mosaic:
            return
        case .text:
            guard updated.color != ink || updated.fontSize != textSize else { return }
            updated.fontSize = textSize
            updated.rect.size = EditRenderer.textSize(updated.text, fontSize: textSize)
        default:
            guard updated.color != ink || updated.width != strokeWidth else { return }
            updated.width = strokeWidth
        }
        updated.color = ink
        commit(before: old, after: updated)
    }

    func insertImage(_ image: CGImage) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageInsertionError()
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageInsertionError() }
        finishTextEditing()
        cancelDrag()
        tool = nil
        let viewport = visibleRect.isEmpty ? bounds : visibleRect
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(1, viewport.width * 0.65 / size.width, viewport.height * 0.65 / size.height)
        let width = size.width * scale, height = size.height * scale
        let rect = CGRect(x: viewport.midX - width / 2, y: viewport.midY - height / 2,
                          width: width, height: height)
        commit(before: nil, after: EditLayer(kind: .image, rect: rect, imageData: data as Data))
        window?.makeFirstResponder(self)
    }

    private struct ImageInsertionError: LocalizedError {
        var errorDescription: String? { L("插入的图片无法转换为 PNG。", "The inserted image could not be converted to PNG.") }
    }

    override func mouseDown(with event: NSEvent) {
        beginInteraction(at: documentPoint(event), clickCount: event.clickCount)
    }

    func beginInteraction(at point: CGPoint, clickCount: Int = 1) {
        finishTextEditing()
        cancelDrag()
        window?.makeFirstResponder(self)
        start = point
        moved = false
        if tool == nil || tool == .image || tool == .text {
            if tool != .text, let layer = selection, layer.kind == .image,
               handle(at: layer.rect).insetBy(dx: -4 / zoom, dy: -4 / zoom).contains(point) {
                drag = .resizing(layer)
                preview = layer
                return
            }
            let hit = layers.last { Self.hits($0, at: point, tolerance: 4 / zoom) }
            if tool == .text && hit?.kind != .text {
                beginText(at: point, layer: nil)
                return
            }
            select(hit)
            if let hit {
                if hit.kind == .text && clickCount >= 2 {
                    beginText(at: hit.rect.origin, layer: hit)
                } else {
                    drag = .moving(hit)
                    preview = hit
                }
            }
            return
        }
        guard let tool else { return }
        select(nil)
        let points: [CGPoint] = tool == .pen || tool == .highlighter || tool == .arrow ? [point] : []
        drag = .drawing
        preview = EditLayer(kind: tool, rect: CGRect(origin: point, size: .zero),
                            points: points, color: ink, width: strokeWidth)
        invalidateOutline(preview)
    }

    private func documentPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        _ = autoscroll(with: event)
        updateDrag(to: documentPoint(event))
    }

    private func updateDrag(to point: CGPoint) {
        guard let drag else { return }
        let dx = point.x - start.x, dy = point.y - start.y
        if hypot(dx, dy) > 1 / zoom { moved = true }
        guard moved else { return }
        let oldBounds = preview?.paintBounds
        switch drag {
        case .drawing:
            switch preview?.kind {
            case .pen, .highlighter:
                guard let last = preview?.points.last, point != last else { return }
                let rect = Self.box(last, point)
                let extent = preview!.rect.union(rect)
                preview!.rect = extent
                preview!.points.append(point)
                let margin = strokeWidth / 2 + 2
                setNeedsDisplay(rect.insetBy(dx: -margin, dy: -margin))
                return
            case .arrow:
                preview?.points = [start, point]
                preview?.rect = Self.box(start, point)
            default:
                preview?.rect = Self.box(start, point)
            }
        case .moving(let layer):
            // Allow clipped layers to be repositioned while retaining a grabbable part.
            let keepX = min(max(1, layer.rect.width), 8 / zoom)
            let keepY = min(max(1, layer.rect.height), 8 / zoom)
            let offsetX = min(max(dx, keepX - layer.rect.maxX), bounds.maxX - keepX - layer.rect.minX)
            let offsetY = min(max(dy, keepY - layer.rect.maxY), bounds.maxY - keepY - layer.rect.minY)
            preview = layer.translated(dx: offsetX, dy: offsetY)
        case .resizing(let layer):
            let size = layer.rect.size
            let diagonal = size.width * size.width + size.height * size.height
            guard size.width > 0, size.height > 0 else { return }
            let desired = 1 + (dx * size.width + dy * size.height) / diagonal
            let maximum = min((bounds.maxX - layer.rect.minX) / size.width,
                              (bounds.maxY - layer.rect.minY) / size.height)
            let ratio = min(maximum, max(1 / min(size.width, size.height), desired))
            preview?.rect.size = CGSize(width: size.width * ratio, height: size.height * ratio)
        }
        if let oldBounds { setNeedsDisplay(oldBounds.insetBy(dx: -10 / zoom, dy: -10 / zoom)) }
        invalidateOutline(preview)
    }

    override func mouseUp(with event: NSEvent) {
        endInteraction(at: documentPoint(event))
    }

    func endInteraction(at point: CGPoint) {
        guard let drag else { return }
        updateDrag(to: point)
        let result = preview
        cancelDrag()
        guard let result else { return }
        switch drag {
        case .drawing:
            let dot = result.kind == .pen || result.kind == .highlighter
            let line = result.kind == .arrow || result.kind == .rectangle
            if dot || (moved && (line || !result.rect.isEmpty)) {
                commit(before: nil, after: result)
            }
        case .moving(let layer), .resizing(let layer):
            if moved, layer.rect != result.rect {
                commit(before: layer, after: result)
            } else if !moved, layer.kind == .text, tool == .text {
                beginText(at: layer.rect.origin, layer: layer)
            }
        }
    }

    private func cancelDrag() {
        invalidateOutline(drag?.original)
        invalidateOutline(preview)
        drag = nil
        preview = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: deleteSelection()
        case 53:
            cancelDrag()
            select(nil)
        default: super.keyDown(with: event)
        }
    }

    private static func box(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Open shapes are selectable on their ink. A click through the middle of a
    /// circle can therefore still reach a text or image layer beneath it.
    static func hits(_ layer: EditLayer, at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard layer.paintBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        switch layer.kind {
        case .text, .image, .mosaic: return layer.rect.contains(point)
        case .rectangle, .ellipse, .arrow:
            let path: CGPath
            switch layer.kind {
            case .ellipse: path = CGPath(ellipseIn: layer.rect, transform: nil)
            case .arrow:
                guard let arrow = EditRenderer.arrowPath(for: layer) else { return false }
                path = arrow
            default: path = CGPath(rect: layer.rect, transform: nil)
            }
            return path.copy(strokingWithWidth: layer.width + 2 * tolerance, lineCap: .round,
                             lineJoin: .round, miterLimit: 2).contains(point)
        case .pen, .highlighter:
            let radius = layer.width / 2 + tolerance
            if let first = layer.points.first, hypot(point.x - first.x, point.y - first.y) <= radius { return true }
            for (a, b) in zip(layer.points, layer.points.dropFirst()) {
                if nearSegment(point, from: a, to: b, radius: radius) { return true }
            }
            return false
        }
    }

    private static func nearSegment(_ p: CGPoint, from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let projection = (p.x - a.x) * dx + (p.y - a.y) * dy
        let t = lengthSquared == 0 ? 0 : min(1, max(0, projection / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)) <= radius
    }

    private func beginText(at anchor: CGPoint, layer: EditLayer?) {
        cancelDrag()
        select(layer)
        editingLayer = layer
        typingID = layer?.id ?? UUID()
        textAnchor = anchor
        let editor = CanvasTextView(frame: .zero)
        textEditor = editor
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: 1_000_000, height: 1_000_000)
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.backgroundColor = .textBackgroundColor
        editor.string = layer?.text ?? ""
        editor.delegate = self
        editor.setAccessibilityLabel(L("标注文字", "Annotation text"))
        editor.toolTip = L("回车完成，Shift + 回车换行，Esc 取消",
                           "Return to finish, Shift-Return for a new line, Esc to cancel")
        editor.onFinish = { [weak self] save in self?.endText(commit: save) }
        addSubview(editor)
        style(editor)
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        invalidateOutline(layer)
    }

    private func style(_ editor: NSTextView) {
        editor.font = .systemFont(ofSize: textSize)
        editor.textColor = NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: 1)
        layoutTextEditor(editor)
    }

    private func layoutTextEditor(_ editor: NSTextView) {
        var sample = editor.string
        if sample.isEmpty || sample.hasSuffix("\n") { sample += " " }
        let measured = EditRenderer.textSize(sample, fontSize: textSize)
        let size = CGSize(width: min(bounds.width, max(110 / zoom, measured.width + 8)),
                          height: min(bounds.height, max(textSize * 1.4, measured.height + 4)))
        // Near the lower/right edge the typing surface remains reachable. The layer
        // itself retains the exact point the user clicked when editing finishes.
        editor.frame = CGRect(x: min(max(textAnchor.x, 0), bounds.width - size.width),
                              y: min(max(textAnchor.y, 0), bounds.height - size.height),
                              width: size.width, height: size.height)
    }

    func textDidChange(_ notification: Notification) {
        if let editor = textEditor {
            layoutTextEditor(editor)
            onChange?()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let editor = notification.object as? NSTextView, editor === textEditor else { return }
        endText(commit: true, restoreFocus: false)
    }

    func finishTextEditing() { endText(commit: true) }

    /// Autosave even while the insertion point is still in a text annotation.
    /// Capturing the draft leaves keyboard focus, marked text and the undo stack alone.
    var layersForSaving: [EditLayer] {
        guard let editor = textEditor else { return layers }
        var snapshot = layers
        let draft = textLayer(editor.string)
        if let old = editingLayer, let i = snapshot.firstIndex(where: { $0.id == old.id }) {
            if let draft { snapshot[i] = draft } else { snapshot.remove(at: i) }
        } else if let draft {
            snapshot.append(draft)
        }
        return snapshot
    }

    private func textLayer(_ value: String) -> EditLayer? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let old = editingLayer, old.text == value, old.fontSize == textSize, old.color == ink { return old }
        var updated = editingLayer ?? EditLayer(id: typingID, kind: .text, rect: .zero)
        updated.text = value
        updated.color = ink
        updated.fontSize = textSize
        updated.rect = CGRect(origin: textAnchor, size: EditRenderer.textSize(value, fontSize: textSize))
        return updated
    }

    private func endText(commit save: Bool, restoreFocus: Bool = true) {
        guard let editor = textEditor else { return }
        let old = editingLayer
        let updated = textLayer(editor.string)
        let hadFocus = window?.firstResponder === editor
        editingLayer = nil
        textEditor = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        invalidateOutline(old)
        if hadFocus && restoreFocus { window?.makeFirstResponder(self) }
        guard old != updated else { return }
        if save { commit(before: old, after: updated) }
        else { onChange?() } // Escape also rolls back a draft already autosaved to disk.
    }
}

private final class CanvasTextView: NSTextView {
    var onFinish: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        // Let input methods consume Return/Esc to confirm or cancel marked text first.
        if !hasMarkedText() {
            if event.keyCode == 53 {
                onFinish?(false)
                return
            }
            if [36, 76].contains(event.keyCode),
               event.modifierFlags.intersection([.shift, .option]).isEmpty {
                onFinish?(true)
                return
            }
        }
        super.keyDown(with: event)
    }
}

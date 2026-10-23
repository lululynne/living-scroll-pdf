import AppKit

struct PickResult {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let windowTitle: String
    /// Window bounds in global display coordinates (top-left origin), as CGWindowList reports them.
    let windowFrame: CGRect
    /// Chosen region in the same coordinates.
    let region: CGRect
}

/// Global display coordinates (top-left origin) ⇄ AppKit screen coordinates (bottom-left origin).
enum Coords {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func toGlobal(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

enum WindowList {
    struct Info {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
        let title: String
        let bounds: CGRect
    }

    /// Normal app windows, front to back, excluding this app's own.
    static func onScreen() -> [Info] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bd),
                  bounds.width > 40, bounds.height > 40,
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return Info(id: id, pid: pid, owner: d[kCGWindowOwnerName as String] as? String ?? "",
                        title: d[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
    }

    /// The window that receives mouse input at `p`, floating panels included (unlike
    /// `onScreen()`, which lists only the windows one can pick).
    static func frontmost(at p: CGPoint) -> Info? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int, (0..<Int(CGWindowLevelForKey(.dockWindow))).contains(layer),
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bd), bounds.contains(p),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return Info(id: id, pid: pid, owner: d[kCGWindowOwnerName as String] as? String ?? "",
                        title: d[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
        return nil
    }

    static func bounds(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bd = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bd)
    }
}

/// Step 1: hover highlights the window under the cursor, click picks it.
/// Step 2: drag a region inside that window; a plain click takes the whole window.
final class WindowPicker {
    enum Stage { case window, region }

    private(set) var stage = Stage.window
    private var overlays: [PickerOverlay] = []
    private var hovered: WindowList.Info?
    private var chosen: WindowList.Info?
    private var dragStart: CGPoint?
    private(set) var selection: CGRect?
    private let completion: (PickResult?) -> Void

    init(completion: @escaping (PickResult?) -> Void) {
        self.completion = completion
    }

    var highlight: CGRect? { stage == .window ? hovered?.bounds : chosen?.bounds }
    var label: String {
        switch stage {
        case .window:
            let name = hovered.map { $0.owner + ($0.title.isEmpty ? "" : " · " + $0.title) } ?? ""
            return L("点一下选中要截的窗口   \(name)   Esc 取消", "Click the window to capture   \(name)   Esc to cancel")
        case .region:
            return L("在窗口里拖出要截的区域（只框聊天内容最准）· 直接点一下 = 整个窗口 · Esc 返回", "Drag the area to capture (just the chat works best) · click = whole window · Esc to go back")
        }
    }

    func begin() {
        overlays = NSScreen.screens.map { PickerOverlay(screen: $0, picker: self) }
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.orderFrontRegardless() }
        overlays.first?.makeKey()
        moved(to: Coords.toGlobal(NSEvent.mouseLocation))
    }

    func moved(to p: CGPoint) {
        guard stage == .window else { return }
        hovered = WindowList.onScreen().first { $0.bounds.contains(p) }
        redraw()
    }

    func down(at p: CGPoint) {
        switch stage {
        case .window:
            guard let h = hovered else { return }
            chosen = h
            stage = .region
            selection = nil
        case .region:
            guard let c = chosen else { return }
            dragStart = clamp(p, to: c.bounds)
        }
        redraw()
    }

    func dragged(to p: CGPoint) {
        guard stage == .region, let start = dragStart, let c = chosen else { return }
        let q = clamp(p, to: c.bounds)
        selection = CGRect(x: min(start.x, q.x), y: min(start.y, q.y),
                           width: abs(q.x - start.x), height: abs(q.y - start.y)).integral
        redraw()
    }

    func up() {
        guard stage == .region, let c = chosen, dragStart != nil else { return }
        dragStart = nil
        let region: CGRect
        if let s = selection, s.width >= 40, s.height >= 60 {
            region = s
        } else {
            region = c.bounds
        }
        finish(PickResult(windowID: c.id, pid: c.pid, appName: c.owner, windowTitle: c.title,
                          windowFrame: c.bounds, region: region))
    }

    func escape() {
        if stage == .region {
            stage = .window
            chosen = nil
            selection = nil
            moved(to: Coords.toGlobal(NSEvent.mouseLocation))
        } else {
            finish(nil)
        }
    }

    private func finish(_ result: PickResult?) {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        completion(result)
    }

    private func redraw() { overlays.forEach { $0.contentView?.needsDisplay = true } }

    private func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
}

private final class PickerOverlay: NSWindow {
    init(screen: NSScreen, picker: WindowPicker) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
        // Explicit, so clicks over the see-through hole land here instead of the window below.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PickerView(picker: picker)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

private final class PickerView: NSView {
    unowned let picker: WindowPicker

    init(picker: WindowPicker) {
        self.picker = picker
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func global(_ e: NSEvent) -> CGPoint {
        Coords.toGlobal(window!.convertPoint(toScreen: e.locationInWindow))
    }

    override func mouseMoved(with e: NSEvent) { picker.moved(to: global(e)) }
    override func mouseDown(with e: NSEvent) { picker.down(at: global(e)) }
    override func mouseDragged(with e: NSEvent) { picker.dragged(to: global(e)) }
    override func mouseUp(with e: NSEvent) { picker.up() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { picker.escape() }
    }

    /// Global rect → this view's coordinates.
    private func local(_ r: CGRect) -> NSRect {
        let a = Coords.toAppKit(r)
        let origin = window!.frame.origin
        return a.offsetBy(dx: -origin.x, dy: -origin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()

        if let h = picker.highlight {
            let r = local(h)
            NSColor.black.withAlphaComponent(0.01).setFill()
            r.fill(using: .copy)
            if picker.stage == .region {
                NSColor.black.withAlphaComponent(0.18).setFill()
                r.fill()
                if let s = picker.selection {
                    let sr = local(s)
                    NSColor.black.withAlphaComponent(0.01).setFill()
                    sr.fill(using: .copy)
                    NSColor.systemRed.setStroke()
                    let p = NSBezierPath(rect: sr.insetBy(dx: -1, dy: -1))
                    p.lineWidth = 2
                    p.stroke()
                    caption("\(Int(s.width)) × \(Int(s.height))", at: NSPoint(x: sr.minX, y: sr.maxY + 6), small: true)
                }
            }
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
            p.lineWidth = 3
            p.stroke()
        }

        // Instruction pill near the top of the screen that holds the mouse.
        let mouse = NSEvent.mouseLocation
        if window!.frame.contains(mouse) || NSScreen.screens.count == 1 {
            caption(picker.label, at: NSPoint(x: bounds.midX, y: bounds.maxY - 90), small: false, centered: true)
        }
    }

    private func caption(_ text: String, at p: NSPoint, small: Bool, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: small ? 12 : 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var box = NSRect(x: p.x, y: p.y, width: size.width + 24, height: size.height + 12)
        if centered { box.origin.x -= box.width / 2 }
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + 12, y: box.minY + 6), withAttributes: attrs)
    }
}

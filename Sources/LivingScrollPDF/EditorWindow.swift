import AppKit
import UniformTypeIdentifiers

/// The status-bar app has no normal document menu. Keep document shortcuts in
/// this window while leaving text-field shortcuts to the standard Edit menu.
private final class EditorHostWindow: NSWindow {
    var handleShortcut: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if attachedSheet == nil, handleShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let original: CGImage
    private let library: ScrollLibrary
    private var currentDocument: EditDocument
    var documentID: UUID { currentDocument.id }
    private var categoryID: UUID?
    private let canvas: EditCanvas
    private let scroll = NSScrollView()
    private let name = NSTextField()
    private let categories = NSPopUpButton()
    private var categoryRefresh: Task<Void, Never>?
    private let color = NSColorWell()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let sizes = NSPopUpButton()
    private let detail = NSTextField(labelWithString: "")
    private let zoom = NSTextField(labelWithString: "")
    private var toolButtons: [(EditLayerKind?, NSButton)] = []
    private lazy var undoButton = symbolButton("arrow.uturn.backward", EditorCopy.undo, #selector(undoEdits))
    private lazy var redoButton = symbolButton("arrow.uturn.forward", EditorCopy.redo, #selector(redoEdits))
    private lazy var deleteButton = symbolButton("trash", EditorCopy.delete, #selector(deleteLayer))
    private var fitToWidth = true
    private var toolColors: [EditLayerKind: InkColor] = [.highlighter: .yellow]
    private var toolWidths: [EditLayerKind: CGFloat] = [.highlighter: 24]
    private var selectedFontSize: CGFloat = 32
    private(set) var isBusy = false
    private var hasEdits: Bool
    private var changeNumber = 0
    private var autosave: Task<Void, Never>?
    private var activeSave: Task<EditDocument, Error>?
    private var localizeChrome: (() -> Void)?
    var onClose: (() -> Void)?
    var showExportedFiles: (URL) -> Void = { pdf in
        NSWorkspace.shared.activateFileViewerSelecting([pdf])
        NSWorkspace.shared.open(pdf)
    }

    init(document: EditDocument, original: CGImage, categoryID: UUID?, saved: Bool, library: ScrollLibrary = .shared) {
        self.library = library
        self.currentDocument = document
        self.original = original
        self.categoryID = categoryID
        hasEdits = !saved
        canvas = EditCanvas(original: original, layers: document.layers, pointScale: document.record.pointScale)
        let host = EditorHostWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 670),
                                    styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                    backing: .buffered, defer: false)
        super.init(window: host)
        host.delegate = self
        host.isReleasedWhenClosed = false
        host.contentMinSize = NSSize(width: 740, height: 475)
        host.isDocumentEdited = hasEdits
        host.title = document.name + " — " + EditorCopy.editor
        host.handleShortcut = { [weak self] event in self?.shortcut(event) ?? false }
        buildContent(in: host)
        host.center()
        canvas.onChange = { [weak self] in self?.markEdited() }
        canvas.onSelectionChange = { [weak self] in self?.syncTools() }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCategories(_:)),
                                                name: .scrollLibraryDidChange, object: library)
        NotificationCenter.default.addObserver(self, selector: #selector(magnifying(_:)),
                                                name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(updateZoomLabel(_:)),
                                                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        syncTools()
        showDimensions()
        refreshCategories()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        if window?.isVisible != true {
            window?.contentView?.layoutSubtreeIfNeeded()
            fitWidth(nil)
            canvas.scroll(.zero)
            window?.makeFirstResponder(canvas)
        }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent(in host: NSWindow) {
        let root = NSView()
        host.contentView = root
        name.stringValue = currentDocument.name
        name.placeholderString = EditorCopy.name
        name.setAccessibilityLabel(EditorCopy.name)
        name.delegate = self
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        categories.target = self
        categories.action = #selector(chooseCategory)
        categories.setAccessibilityLabel(EditorCopy.category)
        let save = NSButton(title: EditorCopy.save, target: self, action: #selector(saveEdits))
        let export = NSButton(title: EditorCopy.export, target: self, action: #selector(exportEdits))
        export.bezelColor = .controlAccentColor
        let nameLabel = NSTextField(labelWithString: EditorCopy.name)
        let categoryLabel = NSTextField(labelWithString: EditorCopy.category)
        let header = row([nameLabel, name, categoryLabel, categories, save, export])

        let rail = NSVisualEffectView()
        rail.material = .sidebar
        rail.blendingMode = .withinWindow
        let palette = NSStackView()
        palette.orientation = .vertical
        palette.spacing = 4
        let tools: [(EditLayerKind?, String)] = [(nil, "cursorarrow"), (.pen, "pencil.tip"),
            (.highlighter, "highlighter"), (.rectangle, "rectangle"), (.ellipse, "circle"),
            (.arrow, "arrow.up.right"), (.mosaic, "square.grid.3x3.fill"), (.text, "textformat"),
            (.image, "photo.badge.plus")]
        for (kind, symbol) in tools {
            let title = EditorCopy.title(for: kind)
            let button = symbolButton(symbol, title, #selector(chooseTool(_:)), showTitle: true)
            button.tag = toolButtons.count
            toolButtons.append((kind, button))
            palette.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 120).isActive = true
        }
        let paste = symbolButton("doc.on.clipboard", EditorCopy.pasteImage, #selector(pasteImage), showTitle: true)
        paste.widthAnchor.constraint(equalToConstant: 120).isActive = true
        palette.addArrangedSubview(paste)
        rail.addSubview(palette)
        palette.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([palette.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 8),
                                     palette.topAnchor.constraint(equalTo: rail.topAnchor, constant: 12)])

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.005
        scroll.maxMagnification = 8
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = canvas

        color.target = self
        color.action = #selector(changeColor)
        color.toolTip = EditorCopy.adjustColor
        color.setAccessibilityLabel(EditorCopy.adjustColor)
        sizes.target = self
        sizes.action = #selector(changeSize)
        let minus = symbolButton("minus.magnifyingglass", EditorCopy.zoomOut, #selector(zoomOut))
        let plus = symbolButton("plus.magnifyingglass", EditorCopy.zoomIn, #selector(zoomIn))
        let fit = NSButton(title: EditorCopy.fit, target: self, action: #selector(fitWidth(_:)))
        localizeChrome = { [weak self] in
            guard let self else { return }
            nameLabel.stringValue = EditorCopy.name
            categoryLabel.stringValue = EditorCopy.category
            name.placeholderString = EditorCopy.name
            name.setAccessibilityLabel(EditorCopy.name)
            categories.setAccessibilityLabel(EditorCopy.category)
            color.toolTip = EditorCopy.adjustColor
            color.setAccessibilityLabel(EditorCopy.adjustColor)
            for (button, label) in toolButtons.map({ ($0.1, EditorCopy.title(for: $0.0)) })
                    + [(paste, EditorCopy.pasteImage), (undoButton, EditorCopy.undo), (redoButton, EditorCopy.redo),
                       (deleteButton, EditorCopy.delete), (minus, EditorCopy.zoomOut), (plus, EditorCopy.zoomIn),
                       (fit, EditorCopy.fit), (save, EditorCopy.save), (export, EditorCopy.export)] {
                button.title = label
                button.toolTip = label
                button.setAccessibilityLabel(label)
            }
        }
        zoom.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        zoom.alignment = .center
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = row([undoButton, redoButton, deleteButton, color, sizeLabel, sizes,
                          detail, minus, zoom, plus, fit])
        color.widthAnchor.constraint(equalToConstant: 38).isActive = true
        zoom.widthAnchor.constraint(equalToConstant: 44).isActive = true
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true
        categories.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        categories.widthAnchor.constraint(greaterThanOrEqualToConstant: 105).isActive = true

        let topRule = NSBox(), bottomRule = NSBox()
        topRule.boxType = .separator
        bottomRule.boxType = .separator
        for view in [header, topRule, rail, scroll, bottomRule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        for band in [header, topRule, bottomRule, footer] as [NSView] {
            band.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            band.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 52),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor), topRule.heightAnchor.constraint(equalToConstant: 1),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 43),
            bottomRule.bottomAnchor.constraint(equalTo: footer.topAnchor), bottomRule.heightAnchor.constraint(equalToConstant: 1),
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor), rail.widthAnchor.constraint(equalToConstant: 136),
            rail.topAnchor.constraint(equalTo: topRule.bottomAnchor), rail.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: rail.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rail.topAnchor), scroll.bottomAnchor.constraint(equalTo: rail.bottomAnchor)
        ])
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        return stack
    }

    func refreshLanguage() {
        localizeChrome?()
        window?.title = currentDocument.name + " — " + EditorCopy.editor
        syncTools()
        showDimensions()
        refreshCategories()
    }

    private func symbolButton(_ symbol: String, _ title: String, _ action: Selector, showTitle: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = icon
            button.imagePosition = showTitle ? .imageLeading : .imageOnly
        }
        button.bezelStyle = showTitle ? .recessed : .inline
        button.setAccessibilityLabel(title)
        button.toolTip = title
        if showTitle {
            button.setButtonType(.toggle)
            button.alignment = .left
            button.heightAnchor.constraint(equalToConstant: 29).isActive = true
        }
        return button
    }

    @objc private func chooseTool(_ sender: NSButton) {
        canvas.finishTextEditing()
        let kind = toolButtons[sender.tag].0
        guard kind != .image else {
            sender.state = .off
            insertFromFile()
            return
        }
        canvas.tool = kind
        if let kind {
            canvas.ink = toolColors[kind] ?? .coral
            canvas.strokeWidth = toolWidths[kind] ?? 6
            canvas.textSize = selectedFontSize
        }
        syncTools()
        window?.makeFirstResponder(canvas)
    }

    private func syncTools() {
        let selection = canvas.tool == nil || canvas.tool == .text ? canvas.selection : nil
        let kind = selection?.kind ?? canvas.tool
        for (kind, button) in toolButtons { button.state = canvas.tool == kind ? .on : .off }
        let ink = selection?.color ?? canvas.ink
        color.color = NSColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: 1)
        let hasInk = kind != nil && kind != .image && kind != .mosaic
        color.isEnabled = hasInk
        sizeLabel.isHidden = !hasInk
        sizes.isHidden = !hasInk
        if hasInk {
            let isText = kind == .text
            sizeLabel.stringValue = isText ? EditorCopy.fontSize : EditorCopy.lineWidth
            sizes.setAccessibilityLabel(sizeLabel.stringValue)
            let value = isText ? (selection?.fontSize ?? canvas.textSize) : (selection?.width ?? canvas.strokeWidth)
            var choices: [CGFloat] = isText ? [12, 16, 20, 24, 32, 48, 64, 96, 144] : [2, 4, 6, 10, 16, 24, 36, 48]
            if !choices.contains(value) { choices.append(value); choices.sort() }
            sizes.removeAllItems()
            for n in choices {
                sizes.addItem(withTitle: String(format: "%g px", Double(n)))
                sizes.lastItem?.representedObject = NSNumber(value: Double(n))
            }
            sizes.selectItem(at: choices.firstIndex(of: value) ?? 0)
        }
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        deleteButton.isEnabled = canvas.selection != nil
    }

    @objc private func changeColor() {
        guard let rgb = color.color.usingColorSpace(.sRGB) else { return }
        canvas.ink = InkColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        if let kind = canvas.tool { toolColors[kind] = canvas.ink }
        applySelectedStyle()
    }

    @objc private func changeSize() {
        guard let number = sizes.selectedItem?.representedObject as? NSNumber else { return }
        let value = CGFloat(number.doubleValue)
        if (canvas.selection?.kind == .text && canvas.tool == nil) || canvas.tool == .text {
            selectedFontSize = value
            canvas.textSize = value
        } else {
            canvas.strokeWidth = value
            if let kind = canvas.tool { toolWidths[kind] = value }
        }
        applySelectedStyle()
    }

    private func applySelectedStyle() {
        guard let selected = canvas.selection, canvas.tool == nil || canvas.tool == .text else { return }
        // The palette represents all of this layer's style; preserve the controls the user didn't touch.
        if let rgb = color.color.usingColorSpace(.sRGB) {
            canvas.ink = InkColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
        if let value = sizes.selectedItem?.representedObject as? NSNumber {
            if selected.kind == .text { canvas.textSize = CGFloat(value.doubleValue) }
            else { canvas.strokeWidth = CGFloat(value.doubleValue) }
        }
        canvas.applyStyleToSelection()
    }

    @objc private func undoEdits() { canvas.undoEdit() }
    @objc private func redoEdits() { canvas.redoEdit() }
    @objc private func deleteLayer() { canvas.deleteSelection() }

    private func insertFromFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.insertImage(from: NSImage(contentsOf: url))
        }
    }

    @objc private func pasteImage(_ sender: NSButton? = nil) {
        sender?.state = .off
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard) {
            insertImage(from: image)
        } else if let url = (pasteboard.readObjects(forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            insertImage(from: NSImage(contentsOf: url))
        } else {
            showError(EditorCopy.emptyPasteboard)
        }
    }

    private func insertImage(from image: NSImage?) {
        guard let pixels = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showError(EditorCopy.invalidImage)
            return
        }
        do {
            try canvas.insertImage(pixels)
            window?.makeFirstResponder(canvas)
        } catch { showError(error.localizedDescription) }
    }

    @objc private func magnifying(_ notification: Notification) { fitToWidth = false }
    @objc private func updateZoomLabel(_ notification: Notification? = nil) {
        let text = "\(Int((scroll.magnification * 100).rounded()))%"
        if zoom.stringValue != text { zoom.stringValue = text }
    }
    @objc private func zoomIn() { zoomBy(1.25) }
    @objc private func zoomOut() { zoomBy(0.8) }

    private func zoomBy(_ factor: CGFloat) {
        fitToWidth = false
        let visible = canvas.visibleRect
        let scale = min(scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * factor))
        scroll.setMagnification(scale, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        updateZoomLabel()
    }

    @objc private func fitWidth(_ sender: Any?) {
        fitToWidth = true
        let width = scroll.contentView.frame.width
        guard width > 0 else { return }
        let scale = width / CGFloat(original.width)
        scroll.minMagnification = min(0.005, scale)
        scroll.maxMagnification = max(8, scale)
        let top = canvas.visibleRect.minY
        scroll.magnification = scale
        canvas.scroll(CGPoint(x: 0, y: top))
        updateZoomLabel()
    }

    func windowDidResize(_ notification: Notification) {
        if fitToWidth { fitWidth(nil) }
    }

    @objc private func refreshCategories(_ notification: Notification? = nil) {
        categoryRefresh?.cancel()
        let library = self.library
        categoryRefresh = Task {
            do {
                let available = try await Task.detached { try library.categories() }.value
                guard !Task.isCancelled else { return }
                updateCategories(available)
            } catch {
                guard !Task.isCancelled else { return }
                detail.stringValue = error.localizedDescription
                detail.toolTip = detail.stringValue
            }
        }
    }

    private func updateCategories(_ available: [ScrollCategory]) {
        if let id = categoryID, !available.contains(where: { $0.id == id }) { categoryID = nil }
        categories.removeAllItems()
        categories.addItem(withTitle: EditorCopy.uncategorized)
        for item in available {
            categories.menu?.addItem(NSMenuItem(title: item.name, action: nil, keyEquivalent: ""))
            categories.lastItem?.representedObject = item.id
        }
        categories.selectItem(at: categoryID.flatMap { id in available.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
        categories.menu?.addItem(.separator())
        categories.addItem(withTitle: EditorCopy.newCategory)
        categories.lastItem?.tag = 1
    }

    @objc private func chooseCategory() {
        if categories.selectedItem?.tag != 1 {
            categoryID = categories.selectedItem?.representedObject as? UUID
            markEdited()
            return
        }
        refreshCategories()
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = EditorCopy.categoryName
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: EditorCopy.create)
        alert.addButton(withTitle: EditorCopy.cancel)
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue, library = self.library
            let progress = showProgress(L("正在创建分类…", "Creating category…"), in: window)
            Task {
                do {
                    self.categoryID = try await Task.detached(priority: .userInitiated) { try library.addCategory(name).id }.value
                    self.refreshCategories()
                    self.markEdited()
                    window.endSheet(progress)
                    self.isBusy = false
                } catch {
                    window.endSheet(progress)
                    self.isBusy = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) { markEdited() }

    private func showDimensions() {
        let dimensions = "\(original.width) × \(original.height) px"
        detail.stringValue = currentDocument.record.isPartial ? EditorCopy.partial + " · " + dimensions : dimensions
        detail.toolTip = detail.stringValue
    }

    private func markEdited() {
        changeNumber += 1
        hasEdits = true
        window?.isDocumentEdited = true
        showDimensions()
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self else { return }
            do { _ = try await saveCurrentEdits() }
            catch is CancellationError { return }
            catch { showSaveProblem(error) }
        }
    }

    func showSaveProblem(_ error: Error) {
        detail.stringValue = EditorCopy.librarySaveFailed + " " + error.localizedDescription
        detail.toolTip = detail.stringValue
    }

    private func snapshot() -> EditDocument {
        var draft = currentDocument
        draft.name = Exporter.fileStem(for: draft.record, name: name.stringValue)
        draft.layers = canvas.layersForSaving
        return draft
    }

    /// Coalesce automatic and explicit saves. Each new write uses the revision returned
    /// by its predecessor, even if more edits arrived while that write was running.
    private func saveCurrentEdits() async throws -> EditDocument {
        while let activeSave { _ = try await activeSave.value }
        try Task.checkCancellation()
        guard hasEdits || currentDocument.revision == nil else { return currentDocument }
        let draft = snapshot(), generation = changeNumber, displayedName = name.stringValue
        let original = self.original, library = self.library, chosenCategory = categoryID
        let save = Task { () throws -> EditDocument in
            defer { activeSave = nil }
            let stored = try await Task.detached(priority: .userInitiated) {
                try library.save(draft, original: original, categoryID: chosenCategory)
            }.value
            currentDocument = stored
            window?.title = stored.name + " — " + EditorCopy.editor
            if stored.id != draft.id && name.stringValue == displayedName { name.stringValue = stored.name }
            if changeNumber == generation {
                hasEdits = false
                window?.isDocumentEdited = false
                detail.stringValue = stored.id == draft.id ? EditorCopy.saved : EditorCopy.savedCopy
                detail.toolTip = detail.stringValue
            }
            return stored
        }
        activeSave = save
        return try await save.value
    }

    @objc private func saveEdits() { persist(export: false) }
    @objc private func exportEdits() { persist(export: true) }

    private func showProgress(_ title: String, in window: NSWindow) -> NSPanel {
        isBusy = true
        let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 255, height: 76), styleMask: [.titled],
                               backing: .buffered, defer: false)
        let label = NSTextField(labelWithString: title)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let contents = row([spinner, label])
        contents.distribution = .gravityAreas
        progress.contentView = contents
        window.beginSheet(progress)
        return progress
    }

    private func persist(export: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !isBusy, let window else { completion?(false); return }
        canvas.finishTextEditing()
        window.makeFirstResponder(canvas)
        autosave?.cancel()
        if export { canvas.releaseRenderCaches() }
        let progress = showProgress(export ? EditorCopy.exporting : EditorCopy.saving, in: window)
        Task {
            var document = snapshot()
            var libraryProblem: Error?
            do {
                document = try await saveCurrentEdits()
                name.stringValue = document.name
            } catch { libraryProblem = error }

            let stored = document, original = self.original, library = self.library
            var published: URL?
            var exportProblem: Error?
            if export {
                do {
                    let pdf = try await Task.detached(priority: .userInitiated) {
                        try EditorExport.write(stored, original: original, folder: library.outputFolder,
                                               legacyFolders: library.legacyOutputFolders)
                    }.value
                    published = pdf
                    if libraryProblem == nil {
                        do { try await Task.detached { try library.recordExport(pdf, for: stored.id) }.value }
                        catch { libraryProblem = error }
                    }
                } catch { exportProblem = error }
            }
            window.endSheet(progress)
            isBusy = false
            if let published {
                showExportedFiles(published)
                if let libraryProblem {
                    showError(libraryProblem.localizedDescription, title: EditorCopy.exportedWithoutLibrary)
                } else if stored.layers.contains(where: { $0.kind == .mosaic }),
                          !UserDefaults.standard.bool(forKey: "explainedPrivateRedactionOriginal") {
                    UserDefaults.standard.set(true, forKey: "explainedPrivateRedactionOriginal")
                    let notice = NSAlert()
                    notice.messageText = EditorCopy.redactionExported
                    notice.informativeText = EditorCopy.privateOriginalNotice
                    notice.beginSheetModal(for: window, completionHandler: nil)
                }
                completion?(true)
            } else if let exportProblem {
                let message = [exportProblem.localizedDescription, libraryProblem?.localizedDescription]
                    .compactMap { $0 }.joined(separator: "\n")
                showError(message, title: libraryProblem == nil ? EditorCopy.savedExportFailed : EditorCopy.failed)
                completion?(false)
            } else if let libraryProblem {
                showError(libraryProblem.localizedDescription)
                completion?(false)
            } else {
                completion?(true)
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isBusy, sender.attachedSheet == nil else { return false }
        canvas.finishTextEditing()
        guard hasEdits else { return true }
        reviewBeforeClosing { _ in }
        return false
    }

    func reviewBeforeClosing(_ completion: @escaping (Bool) -> Void) {
        guard let sender = window, !isBusy, sender.attachedSheet == nil else { completion(false); return }
        canvas.finishTextEditing()
        autosave?.cancel()
        if let activeSave {
            Task {
                _ = await activeSave.result
                reviewBeforeClosing(completion)
            }
            return
        }
        guard hasEdits else { sender.close(); completion(true); return }
        let alert = NSAlert()
        alert.messageText = EditorCopy.unsaved
        alert.informativeText = name.stringValue
        alert.addButton(withTitle: EditorCopy.save)
        alert.addButton(withTitle: EditorCopy.cancel).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: EditorCopy.discard).hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { [weak self] result in
            guard let self else { completion(false); return }
            switch result {
            case .alertFirstButtonReturn:
                persist(export: false) { saved in
                    if saved { sender.close() }
                    completion(saved)
                }
            case .alertThirdButtonReturn:
                sender.close()
                completion(true)
            default:
                scheduleAutosave()
                completion(false)
            }
        }
    }

    func needsAttentionBeforeQuit() -> Bool {
        guard !isBusy else { return true }
        canvas.finishTextEditing()
        return hasEdits
    }

    func windowWillClose(_ notification: Notification) {
        autosave?.cancel()
        categoryRefresh?.cancel()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    private func showError(_ message: String, title: String = EditorCopy.failed) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("好", "OK"))
        alert.beginSheetModal(for: window)
    }

    private func shortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let typing = window?.firstResponder is NSTextView
        switch key {
        case "s" where flags == .command: saveEdits()
        case "e" where flags == [.command, .shift]: exportEdits()
        case "w" where flags == .command: window?.performClose(nil)
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "0": fitWidth(nil)
        case "v" where !typing && flags == .command: pasteImage()
        case "z" where !typing:
            if flags.contains(.shift) { redoEdits() } else { undoEdits() }
        default: return false
        }
        return true
    }
}

/// All export surfaces use one flattened raster. In particular a redacted PDF
/// contains no selectable text or original image hidden beneath a mosaic.
enum EditorExport {
    static func write(_ document: EditDocument, original: CGImage, folder: URL = Exporter.outputFolder,
                      legacyFolders: [URL] = []) throws -> URL {
        var record = document.record
        record.editingProjectID = document.id
        record.editLayerCount = document.layers.count
        return try Exporter.export(original, record: record, folder: folder, name: document.name,
                                   layers: document.layers, legacyFolders: legacyFolders)
    }
}

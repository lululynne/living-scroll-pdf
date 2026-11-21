import AppKit
import UniformTypeIdentifiers

private final class LibraryTableView: NSTableView {
    var selectionMenu: (() -> NSMenu?)?
    var editName: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        guard clicked >= 0 else { return nil }
        window?.makeFirstResponder(self)
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        return selectionMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if event.clickCount == 2, clicked >= 0, column(at: point) == column(withIdentifier: NSUserInterfaceItemIdentifier("file")) {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
            editName?(clicked)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let library: ScrollLibrary
    private let onDelete: (UUID) -> Void
    private let onOpen: (UUID) -> Void
    private let categoryPicker = NSPopUpButton()
    private let manage = NSButton()
    private let search = NSSearchField()
    private let table = LibraryTableView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton()
    private let openButton = NSButton()
    private let deleteButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var categories: [ScrollCategory] = []
    private var rows: [ScrollEntry] = []
    private var filter = ScrollCategoryFilter.all
    private var loading = false
    private let dates = DateFormatter()
    private var displayedChinese: Bool?
    private var reload: Task<Void, Never>?
    private var renaming: (id: UUID, field: NSTextField)?

    init(library: ScrollLibrary = .shared, onDelete: @escaping (UUID) -> Void, onOpen: @escaping (UUID) -> Void) {
        self.library = library
        self.onDelete = onDelete
        self.onOpen = onOpen
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 565, height: 320)
        window.isReleasedWhenClosed = false
        window.center()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        buildContent()
        applyLanguage()
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged(_:)),
                                                name: .scrollLibraryDidChange, object: library)
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged(_:)),
                                                name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        applyLanguage()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        categoryPicker.target = self
        categoryPicker.action = #selector(selectCategory)
        manage.target = self
        manage.action = #selector(categoryMenu(_:))
        manage.bezelStyle = .accessoryBarAction
        search.sendsSearchStringImmediately = true
        search.delegate = self
        let space = NSView()
        let bar = NSStackView(views: [categoryPicker, manage, space, search])
        bar.spacing = 6
        bar.alignment = .centerY
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        categoryPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
        search.widthAnchor.constraint(equalToConstant: 208).isActive = true

        for (key, width, minWidth) in [
            ("file", 360.0, 130.0),
            ("category", 132.0, 70.0),
            ("date", 190.0, 140.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.width = width
            column.minWidth = minWidth
            column.resizingMask = key == "file" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.style = .inset
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openRow(_:))
        table.selectionMenu = { [weak self] in self?.rowMenu() }
        table.editName = { [weak self] row in
            guard let self, self.rows.indices.contains(row) else { return }
            self.beginRenaming(self.rows[row].id)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        empty.alignment = .center
        empty.textColor = .secondaryLabelColor
        empty.maximumNumberOfLines = 3

        importButton.bezelStyle = .rounded
        importButton.target = self
        importButton.action = #selector(importPNG)
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openRow(_:))
        openButton.isEnabled = false
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(confirmDeletion)
        deleteButton.isEnabled = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [importButton, spinner, NSView(), deleteButton, openButton])
        footer.alignment = .centerY
        for v in [bar, scroll, empty, footer] {
            content.addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 20),
            empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -20),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footer.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        window?.initialFirstResponder = search
    }

    @objc nonisolated private func defaultsChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.displayedChinese != Lang.isChinese else { return }
            self.applyLanguage()
            if self.window?.isVisible == true { self.refresh() }
        }
    }

    private func applyLanguage() {
        guard displayedChinese != Lang.isChinese else { return }
        displayedChinese = Lang.isChinese
        window?.title = EditorCopy.library
        dates.locale = Lang.isChinese ? Locale(identifier: "zh_Hans") : Locale(identifier: "en")
        categoryPicker.setAccessibilityLabel(L("按分类筛选", "Filter by category"))
        let manageLabel = L("管理分类", "Manage Categories")
        manage.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: manageLabel)
        manage.imagePosition = .imageOnly
        manage.toolTip = manageLabel
        search.placeholderString = L("搜索文件名", "Search filenames")
        search.setAccessibilityLabel(search.placeholderString)
        table.setAccessibilityLabel(L("已保存的长截图", "Saved long screenshots"))
        for (key, label) in [("file", EditorCopy.name), ("category", EditorCopy.category),
                             ("date", L("截图日期", "Capture Date"))] {
            table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.title = label
        }
        importButton.title = L("打开已有 PNG…", "Open Existing PNG…")
        openButton.title = L("继续编辑", "Continue Editing")
        deleteButton.title = EditorCopy.deleteCapture
    }

    @objc private func libraryChanged(_ notification: Notification) {
        if window?.isVisible == true { refresh() }
    }

    private func refresh() {
        // Reloading a view-based table would detach its active field editor.
        // Finishing the rename always requests the latest rows and categories.
        guard renaming == nil else { return }
        reload?.cancel()
        let library = self.library, query = search.stringValue, requested = filter
        reload = Task {
            do {
                let (available, current, entries) = try await Task.detached(priority: .userInitiated) {
                    let available = try library.categories()
                    var current = requested
                    if case .category(let id) = current, !available.contains(where: { $0.id == id }) { current = .uncategorized }
                    return (available, current, try library.entries(matching: query, category: current))
                }.value
                guard !Task.isCancelled else { return }
                categories = available
                filter = current
                updateFilter()
                showRows(entries)
            } catch { if !Task.isCancelled { showError(error) } }
        }
    }

    private func updateFilter() {
        categoryPicker.removeAllItems()
        categoryPicker.addItems(withTitles: [L("全部分类", "All Categories"), EditorCopy.uncategorized])
        if !categories.isEmpty { categoryPicker.menu?.addItem(.separator()) }
        for category in categories {
            let item = NSMenuItem(title: category.name, action: nil, keyEquivalent: "")
            item.representedObject = category.id
            categoryPicker.menu?.addItem(item)
        }
        switch filter {
        case .all: categoryPicker.selectItem(at: 0)
        case .uncategorized: categoryPicker.selectItem(at: 1)
        case .category(let id):
            categoryPicker.select(categoryPicker.itemArray.first { $0.representedObject as? UUID == id })
        }
    }

    private func showRows(_ entries: [ScrollEntry]) {
        let selected = Set(selectedIDs)
        rows = entries
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        empty.stringValue = search.stringValue.isEmpty && filter == .all
            ? L("保存一次长截图，或打开已有的 PNG。", "Save a capture or open an existing PNG.")
            : L("没有匹配的长截图。", "No matching screenshots.")
        empty.isHidden = !rows.isEmpty
        updateSelectionButtons()
    }

    @objc private func selectCategory() {
        if let id = categoryPicker.selectedItem?.representedObject as? UUID { filter = .category(id) }
        else { filter = categoryPicker.indexOfSelectedItem == 1 ? .uncategorized : .all }
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field !== search { return }
        refresh()
    }

    private var selectedIDs: [UUID] {
        table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
    }

    private var selectedID: UUID? {
        table.numberOfSelectedRows == 1 && rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let key = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let cell: NSTableCellView
        if let recycled = table.makeView(withIdentifier: key, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = key
            let label = NSTextField(labelWithString: "")
            if key.rawValue == "file" { label.delegate = self }
            label.lineBreakMode = key.rawValue == "file" ? .byTruncatingMiddle : .byTruncatingTail
            label.textColor = key.rawValue == "file" ? .labelColor : .secondaryLabelColor
            cell.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        switch key.rawValue {
        case "file":
            cell.textField?.stringValue = displayedName(for: entry)
        case "category":
            cell.textField?.stringValue = categories.first { $0.id == entry.categoryID }?.name ?? EditorCopy.uncategorized
        default: cell.textField?.stringValue = dates.string(from: entry.date)
        }
        cell.toolTip = cell.textField?.stringValue
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionButtons()
    }

    private func updateSelectionButtons() {
        let enabled = renaming == nil && selectedID != nil
        openButton.isEnabled = enabled
        deleteButton.isEnabled = enabled
    }

    private func displayedName(for entry: ScrollEntry) -> String {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return entry.matchingFilename(query) ?? entry.name
    }

    private struct CategoryMove {
        let ids: [UUID]
        let category: UUID?
    }

    private func rowMenu() -> NSMenu? {
        let ids = selectedIDs
        guard !ids.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rename = menu.addItem(withTitle: L("重命名…", "Rename…"), action: #selector(renameRow(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = ids.first
        rename.isEnabled = ids.count == 1
        let move = menu.addItem(withTitle: L("移到分类", "Move to Category"), action: nil, keyEquivalent: "")
        let destinations = NSMenu()
        destinations.autoenablesItems = false
        func addDestination(_ title: String, _ id: UUID?) {
            let item = destinations.addItem(withTitle: title, action: #selector(moveRows(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CategoryMove(ids: ids, category: id)
        }
        addDestination(EditorCopy.uncategorized, nil)
        if !categories.isEmpty { destinations.addItem(.separator()) }
        for category in categories { addDestination(category.name, category.id) }
        destinations.addItem(.separator())
        let create = destinations.addItem(withTitle: EditorCopy.newCategory, action: #selector(createCategoryForRows(_:)), keyEquivalent: "")
        create.target = self
        create.representedObject = ids
        move.submenu = destinations
        return menu
    }

    @objc private func moveRows(_ sender: NSMenuItem) {
        guard let move = sender.representedObject as? CategoryMove else { return }
        updateLibrary { library in
            try library.setCategory(ids: move.ids, category: move.category)
            return nil
        }
    }

    @objc private func createCategoryForRows(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? [UUID] { editCategory(nil, assigning: ids) }
    }

    @objc private func renameRow(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { beginRenaming(id) }
    }

    private func beginRenaming(_ id: UUID) {
        guard let window, let row = rows.firstIndex(where: { $0.id == id }) else { return }
        if renaming != nil { finishRenaming(with: nil) }
        table.scrollRowToVisible(row)
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("file"))
        guard let field = (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField else { return }
        reload?.cancel()
        renaming = (id, field)
        openButton.keyEquivalent = ""
        updateSelectionButtons()
        // A search result can be displaying an older exported filename.
        field.stringValue = rows[row].name
        field.isEditable = true
        field.isBezeled = true
        field.drawsBackground = true
        if window.makeFirstResponder(field) { field.currentEditor()?.selectAll(nil) }
        else { finishRenaming(with: nil) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard control === renaming?.field, !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.cancelOperation(_:)): finishRenaming(with: nil)
        case #selector(NSResponder.insertNewline(_:)): finishRenaming(with: textView.string)
        default: return false
        }
        window?.makeFirstResponder(table)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === renaming?.field else { return }
        finishRenaming(with: field.stringValue)
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        if renaming?.field.isDescendant(of: rowView) == true { finishRenaming(with: nil) }
    }

    private func finishRenaming(with name: String?) {
        guard let (id, field) = renaming else { return }
        renaming = nil
        _ = field.abortEditing()
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        let entry = rows.first { $0.id == id }
        if let entry { field.stringValue = displayedName(for: entry) }
        openButton.keyEquivalent = "\r"
        updateSelectionButtons()
        if let name, name != entry?.name {
            updateLibrary { library in
                try library.rename(id: id, to: name)
                return nil
            }
        } else { refresh() }
    }

    @objc private func confirmDeletion() {
        guard let window, let id = selectedID, let entry = rows.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = EditorCopy.confirmDeleteCapture(entry.name)
        alert.informativeText = EditorCopy.deleteCaptureDetails
        alert.addButton(withTitle: EditorCopy.cancel).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: EditorCopy.deleteCapture).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            Task {
                do {
                    let library = self.library
                    try await Task.detached(priority: .userInitiated) { try library.delete(id) }.value
                    self.onDelete(id)
                    self.refresh()
                } catch { self.showError(error) }
            }
        }
    }

    @objc private func openRow(_ sender: NSControl) {
        if sender === table {
            if rows.indices.contains(table.clickedRow) { onOpen(rows[table.clickedRow].id) }
        } else if let id = selectedID { onOpen(id) }
    }

    @objc private func categoryMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [(EditorCopy.newCategory, #selector(addCategory)),
                                (L("重命名所选分类…", "Rename Selected Category…"), #selector(renameCategory)),
                                (L("删除所选分类…", "Delete Selected Category…"), #selector(deleteCategory))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action == #selector(addCategory) || selectedCategory != nil
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sender)
    }

    private var selectedCategory: ScrollCategory? {
        guard case .category(let id) = filter else { return nil }
        return categories.first { $0.id == id }
    }

    @objc private func addCategory() { editCategory(nil) }
    @objc private func renameCategory() { if let selectedCategory { editCategory(selectedCategory) } }

    private func editCategory(_ category: ScrollCategory?, assigning ids: [UUID] = []) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = category == nil ? L("新建分类", "New Category") : L("重命名分类", "Rename Category")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = EditorCopy.categoryName
        field.stringValue = category?.name ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: EditorCopy.save)
        alert.addButton(withTitle: EditorCopy.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            self.updateLibrary { library in
                if let category {
                    try library.renameCategory(category.id, to: name)
                    return nil
                }
                let created = try library.addCategory(name, assigning: ids)
                return ids.isEmpty ? .category(created.id) : nil
            }
        }
    }

    @objc private func deleteCategory() {
        guard let window, let category = selectedCategory else { return }
        let alert = NSAlert()
        alert.messageText = L("删除「\(category.name)」？", "Delete “\(category.name)”?")
        alert.informativeText = L("这个分类中的截图会保留在「未分类」。", "Its screenshots will stay in Uncategorized.")
        alert.addButton(withTitle: EditorCopy.cancel)
        let remove = alert.addButton(withTitle: L("删除分类", "Delete Category"))
        remove.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.updateLibrary { library in
                try library.deleteCategory(category.id)
                return .uncategorized
            }
        }
    }

    /// A large capture can hold the library's write lock while its first PNG is encoded.
    private func updateLibrary(_ change: @escaping (ScrollLibrary) throws -> ScrollCategoryFilter?) {
        let store = library
        Task {
            do {
                if let next = try await Task.detached(priority: .userInitiated, operation: { try change(store) }).value {
                    filter = next
                }
            } catch { showError(error) }
            refresh()
        }
    }

    @objc private func importPNG() {
        guard let window, !loading else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = library.outputFolder
        panel.prompt = L("打开", "Open")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.loading = true
            self.importButton.isEnabled = false
            self.spinner.startAnimation(nil)
            let library = self.library, categoryID = self.selectedCategory?.id
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try library.importPNG(at: url, categoryID: categoryID) }
                DispatchQueue.main.async {
                    self.loading = false
                    self.importButton.isEnabled = true
                    self.spinner.stopAnimation(nil)
                    switch result {
                    case .success(let id): self.onOpen(id)
                    case .failure(let error): self.showError(error)
                    }
                }
            }
        }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L("无法完成图库操作", "The library operation could not be completed")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}

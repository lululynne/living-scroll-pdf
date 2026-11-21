import AppKit
import UniformTypeIdentifiers

@MainActor
final class LibraryWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let library = ScrollLibrary.shared
    private let onOpen: (UUID) -> Void
    private let categoryPicker = NSPopUpButton()
    private let manage = NSButton()
    private let search = NSSearchField()
    private let table = NSTableView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton()
    private let openButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var categories: [ScrollCategory] = []
    private var rows: [ScrollEntry] = []
    private var filter = ScrollCategoryFilter.all
    private var loading = false
    private let dates = DateFormatter()
    private var displayedChinese: Bool?

    init(onOpen: @escaping (UUID) -> Void) {
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
                                                name: .scrollLibraryDidChange, object: nil)
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
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openRow(_:))
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
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [importButton, spinner, NSView(), openButton])
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
    }

    @objc private func libraryChanged(_ notification: Notification) {
        if window?.isVisible == true { refresh() }
    }

    private func refresh() {
        do {
            categories = try library.categories()
            if case .category(let id) = filter, !categories.contains(where: { $0.id == id }) { filter = .uncategorized }
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
            try reloadRows()
        } catch { showError(error) }
    }

    private func reloadRows() throws {
        let selected = selectedID
        rows = try library.entries(matching: search.stringValue, category: filter)
        table.reloadData()
        table.deselectAll(nil)
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        empty.stringValue = search.stringValue.isEmpty && filter == .all
            ? L("保存一次长截图，或打开已有的 PNG。", "Save a capture or open an existing PNG.")
            : L("没有匹配的长截图。", "No matching screenshots.")
        empty.isHidden = !rows.isEmpty
        openButton.isEnabled = selectedID != nil
    }

    @objc private func selectCategory() {
        if let id = categoryPicker.selectedItem?.representedObject as? UUID { filter = .category(id) }
        else { filter = categoryPicker.indexOfSelectedItem == 1 ? .uncategorized : .all }
        do { try reloadRows() } catch { showError(error) }
    }

    func controlTextDidChange(_ obj: Notification) {
        do { try reloadRows() } catch { showError(error) }
    }

    private var selectedID: UUID? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
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
            let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cell.textField?.stringValue = entry.matchingFilename(query) ?? entry.name
        case "category":
            cell.textField?.stringValue = categories.first { $0.id == entry.categoryID }?.name ?? EditorCopy.uncategorized
        default: cell.textField?.stringValue = dates.string(from: entry.date)
        }
        cell.toolTip = cell.textField?.stringValue
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = selectedID != nil
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

    private func editCategory(_ category: ScrollCategory?) {
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
            self.updateCategories { library in
                if let category {
                    try library.renameCategory(category.id, to: name)
                    return nil
                }
                return .category(try library.addCategory(name).id)
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
            self.updateCategories { library in
                try library.deleteCategory(category.id)
                return .uncategorized
            }
        }
    }

    /// A large capture can hold the library's write lock while its first PNG is encoded.
    private func updateCategories(_ change: @escaping (ScrollLibrary) throws -> ScrollCategoryFilter?) {
        let store = library
        Task {
            do {
                if let next = try await Task.detached(priority: .userInitiated, operation: { try change(store) }).value {
                    filter = next
                }
                refresh()
            } catch { showError(error) }
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

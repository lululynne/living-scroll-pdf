import AppKit
import XCTest
@testable import LivingScrollPDF

final class LibraryWindowTests: XCTestCase {
    private func store() -> ScrollLibrary {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        return ScrollLibrary(outputFolder: base.appendingPathComponent("Exports"), root: base.appendingPathComponent("Library"))
    }

    @discardableResult
    private func save(_ name: String, at time: Int, in library: ScrollLibrary, category: UUID? = nil) throws -> UUID {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 8, bitsPerComponent: 8, bytesPerRow: 16,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let date = Date(timeIntervalSince1970: Double(time))
        let record = CaptureRecord(appName: "Gallery", windowTitle: "", startedAt: date, endedAt: date,
                                   framesStitched: 1, droppedFrames: 0, pixelWidth: 4, pixelHeight: 8, pointScale: 1)
        return try library.save(EditDocument(name: name, record: record), original: XCTUnwrap(context.makeImage()), categoryID: category).id
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private func waitFor(_ message: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition(), message)
    }

    @MainActor private func mouse(in table: NSTableView, at point: NSPoint, double: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: double ? .leftMouseDown : .rightMouseDown,
            location: table.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: try XCTUnwrap(table.window).windowNumber, context: nil, eventNumber: 0, clickCount: double ? 2 : 1, pressure: 1))
    }

    @MainActor private func menu(in table: NSTableView, row: Int) throws -> NSMenu {
        let cell = table.frameOfCell(atColumn: 0, row: row)
        return try XCTUnwrap(table.menu(for: mouse(in: table, at: NSPoint(x: cell.midX, y: cell.midY))))
    }

    @MainActor private func choose(_ item: NSMenuItem) throws {
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    @MainActor func testMoveMenuUsesTheClickedSelectionAndRefreshesTheCurrentFilter() async throws {
        _ = NSApplication.shared
        let library = store(), source = try library.addCategory("Inbox"), archive = try library.addCategory("Archive")
        let first = try save("First", at: 3, in: library, category: source.id)
        let middle = try save("Middle", at: 2, in: library, category: source.id)
        let last = try save("Last", at: 1, in: library, category: source.id)
        let browser = LibraryWindow(library: library, onDelete: { _ in XCTFail() }, onOpen: { _ in XCTFail() })
        let window = try XCTUnwrap(browser.window), content = try XCTUnwrap(window.contentView)
        defer { browser.close() }
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let picker = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        try await waitFor("loaded captures") { table.numberOfRows == 3 }
        picker.selectItem(withTitle: source.name)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker))

        let selection = IndexSet([0, 2])
        table.selectRowIndexes(selection, byExtendingSelection: false)
        let rename = L("重命名…", "Rename…"), move = L("移到分类", "Move to Category")
        let blank = NSPoint(x: 15, y: table.rect(ofRow: 2).maxY + table.rowHeight)
        XCTAssertNil(try table.menu(for: mouse(in: table, at: blank)))
        XCTAssertTrue(try XCTUnwrap(menu(in: table, row: 1).item(withTitle: rename)).isEnabled)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        table.selectRowIndexes(selection, byExtendingSelection: false)
        let context = try menu(in: table, row: 2)
        XCTAssertEqual(table.selectedRowIndexes, selection)
        XCTAssertFalse(try XCTUnwrap(context.item(withTitle: rename)).isEnabled)
        let destinations = try XCTUnwrap(context.item(withTitle: move)?.submenu)
        XCTAssertNotNil(destinations.item(withTitle: EditorCopy.uncategorized))
        XCTAssertNotNil(destinations.item(withTitle: EditorCopy.newCategory))
        try choose(XCTUnwrap(destinations.item(withTitle: archive.name)))
        try await waitFor("moved rows left the current category") { table.numberOfRows == 1 }
        XCTAssertEqual(picker.titleOfSelectedItem, source.name)
        XCTAssertEqual(try library.entries(category: .category(archive.id)).map(\.id), [first, last])
        XCTAssertEqual(try library.entries(category: .category(source.id)).map(\.id), [middle])

        let remaining = try menu(in: table, row: 0)
        try choose(XCTUnwrap(remaining.item(withTitle: move)?.submenu?.item(withTitle: EditorCopy.newCategory)))
        let sheet = try XCTUnwrap(NSApp.windows.first { $0.sheetParent === window })
        let field = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "Later"
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        try await waitFor("new category receives the remaining capture") { table.numberOfRows == 0 }
        let later = try XCTUnwrap(library.categories().first { $0.name == "Later" })
        XCTAssertEqual(try library.entries(category: .category(later.id)).map(\.id), [middle])
        XCTAssertEqual(picker.titleOfSelectedItem, source.name)
    }

    @MainActor func testInlineRenameEditsCurrentNameAndHandlesEscapeAndReturn() async throws {
        _ = NSApplication.shared
        let library = store(), id = try save("Current name", at: 1, in: library)
        try library.recordExport(library.outputFolder.appendingPathComponent("Sent earlier.pdf"), for: id)
        let browser = LibraryWindow(library: library, onDelete: { _ in XCTFail() }, onOpen: { _ in XCTFail("renaming opened the editor") })
        let window = try XCTUnwrap(browser.window), content = try XCTUnwrap(window.contentView)
        defer { browser.close() }
        content.layoutSubtreeIfNeeded()
        let views = descendants(content)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Sent earlier"
        browser.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await waitFor("found by former export name") { table.numberOfRows == 1 }
        func nameField() throws -> NSTextField {
            try XCTUnwrap((table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField)
        }
        func type(_ name: String, then key: String, code: UInt16) throws {
            let editor = try XCTUnwrap(try nameField().currentEditor() as? NSTextView)
            XCTAssertEqual(editor.string, "Current name")
            editor.insertText(name, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            if !window.performKeyEquivalent(with: event) { editor.keyDown(with: event) }
        }
        XCTAssertEqual(try nameField().stringValue, "Sent earlier")
        let context = try menu(in: table, row: 0)
        try choose(XCTUnwrap(context.item(withTitle: L("重命名…", "Rename…"))))
        try type("Discard this", then: "\u{1b}", code: 53)
        XCTAssertEqual(try library.entries().first?.name, "Current name")
        try await waitFor("Escape returned to the matching filename") { try nameField().stringValue == "Sent earlier" }

        let cell = table.frameOfCell(atColumn: 0, row: 0)
        table.mouseDown(with: try mouse(in: table, at: NSPoint(x: cell.midX, y: cell.midY), double: true))
        try type("New / name", then: "\r", code: 36)
        try await waitFor("Return saved the cleaned name") { try library.entries().first?.name == "New - name" }
        XCTAssertEqual(try library.load(id).document.name, "New - name")
        XCTAssertFalse(window.isVisible)
    }
}

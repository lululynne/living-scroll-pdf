import CoreGraphics
import Foundation
import XCTest
@testable import LivingScrollPDF

final class ScrollLibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(_ gray: CGFloat) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 24, height: 48, bitsPerComponent: 8, bytesPerRow: 96,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 48))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func record(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CaptureRecord {
        CaptureRecord(appName: "Fixture", windowTitle: "Journal", startedAt: date.addingTimeInterval(-3), endedAt: date,
                      framesStitched: 7, droppedFrames: 2, pixelWidth: 24, pixelHeight: 48, pointScale: 2)
    }

    func testSidecarRoundTripKeepsTheFirstPNGAndOrderedEditableLayers() throws {
        let root = try folder()
        let library = ScrollLibrary(outputFolder: root)
        let source = try image(0.3)
        let category = try library.addCategory("笔记")
        var document = EditDocument(name: "会议草稿", record: record(), layers: [
            EditLayer(kind: .arrow, rect: CGRect(x: 2, y: 3, width: 10, height: 4),
                      points: [CGPoint(x: 2, y: 3), CGPoint(x: 12, y: 7)], width: 3),
            EditLayer(kind: .text, rect: CGRect(x: 2, y: 8, width: 12, height: 16), fontSize: 14, text: "标注")
        ])
        document = try library.save(document, original: source, categoryID: category.id)
        let original = try library.originalURL(for: document.id)
        let originalBytes = try Data(contentsOf: original)
        let exported = root.appendingPathComponent("会议草稿-2.pdf")
        try library.recordExport(exported, for: document.id)
        document.name = "会议笔记"
        document.layers.swapAt(0, 1)
        document.layers[0].text = "Revised"
        try library.save(document, original: image(1), categoryID: nil)

        let fresh = ScrollLibrary(outputFolder: root)
        let loaded = try fresh.load(document.id)
        XCTAssertEqual(loaded.document.name, "会议笔记")
        XCTAssertEqual(loaded.document.record.startedAt, document.record.startedAt)
        XCTAssertEqual(loaded.document.layers, document.layers)
        XCTAssertEqual(loaded.document.id, document.id)
        XCTAssertEqual(loaded.original.height, source.height)
        XCTAssertNil(loaded.categoryID)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        let adjacent = try FileManager.default.contentsOfDirectory(at: original.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil)
        let sidecars = adjacent.filter { $0.lastPathComponent.hasSuffix(".edit.json") }
        XCTAssertEqual(sidecars.count, 1)
        let saved = try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: XCTUnwrap(sidecars.first)))
        XCTAssertEqual(saved.layers, document.layers)
        XCTAssertEqual(try fresh.importPNG(at: original), document.id)
        XCTAssertEqual(try fresh.entries(matching: "会议笔记.png").map(\.id), [document.id])
        XCTAssertEqual(try fresh.entries(matching: "会议草稿-2.png").map(\.id), [document.id])
    }

    func testDeletingAndRenamingCategoriesPreservePicturesAndDateOrder() throws {
        let root = try folder()
        let library = ScrollLibrary(outputFolder: root)
        let pinned = try library.addCategory(" Pinned ")
        let empty = try library.addCategory("Empty")
        XCTAssertThrowsError(try library.addCategory("pinned"))
        let source = try image(0.5)
        let early = EditDocument(name: "Notes", record: record(at: Date(timeIntervalSince1970: 10)))
        let recent = EditDocument(name: "notes", record: record(at: Date(timeIntervalSince1970: 20)))
        try library.save(early, original: source, categoryID: pinned.id)
        try library.save(recent, original: source, categoryID: nil)
        try library.renameCategory(pinned.id, to: "Research")
        XCTAssertThrowsError(try library.renameCategory(pinned.id, to: empty.name))

        let fresh = ScrollLibrary(outputFolder: root)
        XCTAssertEqual(try fresh.categories().first { $0.id == pinned.id }?.name, "Research")
        XCTAssertEqual(try fresh.entries(matching: "NOTES.PDF").map(\.id), [recent.id, early.id])
        XCTAssertEqual(try fresh.entries(category: .category(pinned.id)).map(\.id), [early.id])
        try fresh.deleteCategory(pinned.id)
        XCTAssertEqual(try library.entries(category: .uncategorized).map(\.id), [recent.id, early.id])
        XCTAssertEqual(try library.load(early.id).document.name, "Notes")
        XCTAssertThrowsError(try library.save(early, original: source, categoryID: pinned.id))
        XCTAssertNil(try library.load(early.id).categoryID)
        XCTAssertEqual(try library.categories(), [empty])
    }

    func testLegacyPartialCaptureAndFlattenedExportReturnToSavedLayers() throws {
        let root = try folder()
        let library = ScrollLibrary(outputFolder: root)
        let legacy = root.appendingPathComponent("Long chat.png")
        try Exporter.writePNG(image(0.3), to: legacy)
        var partial = record()
        partial.isPartial = true
        partial.partialReason = "ended-before-reconnecting"
        partial.gaps = [ContentGap(afterRow: 48, droppedFrames: 2, reason: "ended-before-reconnecting")]
        partial.pngSHA256 = try Exporter.sha256(of: legacy)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(partial).write(to: legacy.deletingPathExtension().appendingPathExtension("json"))

        let id = try library.importPNG(at: legacy)
        let opened = try library.load(id)
        XCTAssertTrue(opened.document.record.isPartial)
        XCTAssertEqual(opened.document.record.gaps, partial.gaps)
        XCTAssertEqual(opened.document.record.pointScale, partial.pointScale)
        XCTAssertEqual(opened.document.record.endedAt, partial.endedAt)
        XCTAssertEqual(try Exporter.sha256(of: library.originalURL(for: id)), partial.pngSHA256)
        var revised = opened.document
        revised.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 5, height: 5))]
        try library.save(revised, original: opened.original, categoryID: nil)
        XCTAssertEqual(try library.importPNG(at: legacy), id)

        let flattened = root.appendingPathComponent("Long chat marked.png")
        try Exporter.writePNG(image(0.8), to: flattened)
        partial.editingProjectID = id
        partial.pngSHA256 = try Exporter.sha256(of: flattened)
        let json = flattened.deletingPathExtension().appendingPathExtension("json")
        try encoder.encode(partial).write(to: json)
        XCTAssertEqual(try library.importPNG(at: flattened), id)
        XCTAssertEqual(try library.load(id).document.layers, revised.layers)
        try Exporter.writePNG(image(1), to: flattened)
        XCTAssertThrowsError(try library.importPNG(at: flattened))
        XCTAssertEqual(try library.entries().count, 1)
    }

    func testPNGWithoutRecordUsesImportMetadataAndKeepsSameNamedFilesDistinct() throws {
        let root = try folder()
        let other = try folder()
        let library = ScrollLibrary(outputFolder: root)
        let a = root.appendingPathComponent("scan.png"), b = other.appendingPathComponent("scan.png")
        try Exporter.writePNG(image(0.25), to: a)
        try Exporter.writePNG(image(0.75), to: b)
        let id = try library.importPNG(at: a), otherID = try library.importPNG(at: b)
        XCTAssertNotEqual(id, otherID)
        XCTAssertEqual(try library.importPNG(at: a), id)
        let doc = try library.load(id).document
        XCTAssertEqual(doc.name, "scan")
        XCTAssertEqual(doc.record.framesStitched, 0)
        XCTAssertEqual(doc.record.pixelHeight, 48)
        XCTAssertEqual(try library.entries().count, 2)
    }

    func testLocalizedDesktopFoldersUseTheExistingIndex() throws {
        let desktop = try folder()
        let chinese = desktop.appendingPathComponent("卷轴PDF", isDirectory: true)
        let english = desktop.appendingPathComponent("Living Scroll PDF", isDirectory: true)
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        XCTAssertEqual(ScrollLibrary.existingDesktopFolder(preferred: chinese), chinese)
        try ScrollLibrary(outputFolder: chinese).addCategory("Projects")
        XCTAssertEqual(ScrollLibrary.existingDesktopFolder(preferred: english), chinese)
    }

    func testIndependentWritersMergeAgainstLatestIndex() throws {
        let root = try folder()
        let count = 12
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do { try ScrollLibrary(outputFolder: root).addCategory("Folder \(i)") }
            catch { lock.lock(); failures.append(error); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(try ScrollLibrary(outputFolder: root).categories().count, count)
    }

    func testSimultaneousEditsToOneOriginalKeepBothVersions() throws {
        let root = try folder(), source = try image(0.4)
        let first = ScrollLibrary(outputFolder: root), second = ScrollLibrary(outputFolder: root)
        var a = try first.save(EditDocument(name: "Meeting", record: record()), original: source, categoryID: nil)
        var b = try second.load(a.id).document
        a.layers = [EditLayer(kind: .text, rect: CGRect(x: 1, y: 1, width: 20, height: 14), text: "A")]
        try first.save(a, original: source, categoryID: nil)
        b.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 16, height: 16))]
        var copy = try second.save(b, original: source, categoryID: nil)
        XCTAssertNotEqual(copy.id, a.id)
        XCTAssertEqual(try first.load(a.id).document.layers, a.layers)
        XCTAssertEqual(try second.load(copy.id).document.layers, b.layers)
        XCTAssertEqual(try Exporter.sha256(of: first.originalURL(for: a.id)),
                       try Exporter.sha256(of: second.originalURL(for: copy.id)))
        copy.name = "Redacted meeting"
        XCTAssertEqual(try second.save(copy, original: source, categoryID: nil).id, copy.id)
        XCTAssertEqual(try first.entries().count, 2)
    }
}

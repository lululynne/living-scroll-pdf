import CoreGraphics
import Foundation
import XCTest
@testable import LivingScrollPDF

private extension ScrollLibrary {
    convenience init(testDirectory: URL) {
        self.init(outputFolder: testDirectory.appendingPathComponent("Exports", isDirectory: true),
                  root: testDirectory.appendingPathComponent("Library", isDirectory: true))
    }
}

final class ScrollLibraryTests: XCTestCase {
    private func folder(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
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
        let library = ScrollLibrary(testDirectory: root)
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

        let fresh = ScrollLibrary(testDirectory: root)
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
        let library = ScrollLibrary(testDirectory: root)
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

        let fresh = ScrollLibrary(testDirectory: root)
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
        let library = ScrollLibrary(testDirectory: root)
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
        let library = ScrollLibrary(testDirectory: root)
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

    /// Write the shape shipped in 8da033b, independent of the current library writer.
    private func legacyFixture(at output: URL, document: EditDocument, original: CGImage,
                               categoryID: UUID) throws -> (directory: URL, png: URL) {
        let hidden = output.appendingPathComponent(".living-scroll-library", isDirectory: true)
        let folder = hidden.appendingPathComponent("projects/" + document.id.uuidString, isDirectory: true)
        let revision = try XCTUnwrap(document.revision)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("original.png")
        try Exporter.writePNG(original, to: png)
        try JSONEncoder().encode(document).write(to: folder.appendingPathComponent(revision.uuidString + ".edit.json"))
        let entry: [String: Any] = ["id": document.id.uuidString, "name": document.name,
                                    "date": document.record.endedAt.timeIntervalSinceReferenceDate,
                                    "categoryID": categoryID.uuidString, "directoryID": document.id.uuidString,
                                    "revision": revision.uuidString, "exportedStems": ["Shared copy"]]
        let index: [String: Any] = ["version": 1, "entries": [entry],
                                    "categories": [["id": categoryID.uuidString, "name": "Notes"]]]
        try JSONSerialization.data(withJSONObject: index).write(to: hidden.appendingPathComponent("index.json"))
        return (hidden, png)
    }

    func testMigratesBothLocalizedLibrariesAndConfirmedDeletionRemovesOnlyPrivateFiles() throws {
        let base = try folder(), fm = FileManager.default
        let output = base.appendingPathComponent("Desktop/卷轴PDF", isDirectory: true)
        let english = base.appendingPathComponent("Desktop/Living Scroll PDF", isDirectory: true)
        // On a machine with an external volume the same fixture exercises the verified
        // copy instead of the same-volume rename. The override only contains test data.
        let destination = try ProcessInfo.processInfo.environment["JZ_TEST_MIGRATION_VOLUME"].map {
            try folder(in: URL(fileURLWithPath: $0, isDirectory: true))
        } ?? base
        let support = destination.appendingPathComponent("Application Support/LivingScrollPDF/Library", isDirectory: true)
        let privateStore = ScrollLibrary(outputFolder: output, root: support, legacyOutputFolders: [])
        let source = try image(0.4)
        let existing = try privateStore.save(EditDocument(name: "Earlier", record: record()), original: source, categoryID: nil)
        var doc = EditDocument(name: "Meeting", record: record(), layers: [
            EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 4, width: 20, height: 14))
        ], revision: UUID())
        let category = UUID()
        let legacy = try legacyFixture(at: output, document: doc, original: source, categoryID: category)
        let digest = try Exporter.sha256(of: legacy.png)
        let second = EditDocument(name: "Chat", record: record(), revision: UUID())
        let other = try legacyFixture(at: english, document: second, original: source, categoryID: UUID())
        let published = output.appendingPathComponent("Meeting.pdf")
        try Data("already shared".utf8).write(to: published)
        func launch() -> ScrollLibrary {
            ScrollLibrary(outputFolder: output, root: support, legacyOutputFolders: [output, english])
        }
        let migrated = launch()
        try migrated.prepare()
        XCTAssertFalse(fm.fileExists(atPath: legacy.directory.path))
        XCTAssertFalse(fm.fileExists(atPath: other.directory.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), ["Meeting.pdf"])
        XCTAssertEqual((try fm.attributesOfItem(atPath: support.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(Set(try migrated.entries().map(\.id)), [existing.id, doc.id, second.id])
        XCTAssertEqual(try migrated.entries(matching: "Shared copy.pdf").count, 2)
        XCTAssertEqual(try migrated.categories().map(\.name), ["Notes"])
        XCTAssertEqual(try migrated.load(doc.id).document.layers, doc.layers)
        XCTAssertEqual(try migrated.load(doc.id).categoryID, try migrated.categories().first?.id)
        doc.name = "Revised"
        doc = try migrated.save(doc, original: source, categoryID: nil)
        let project = try migrated.originalURL(for: doc.id).deletingLastPathComponent()
        XCTAssertTrue(project.path.hasPrefix(support.path + "/"))
        XCTAssertEqual(try Exporter.sha256(of: migrated.originalURL(for: doc.id)), digest)

        try launch().delete(doc.id)
        XCTAssertFalse(fm.fileExists(atPath: project.path))
        XCTAssertThrowsError(try migrated.save(doc, original: source, categoryID: nil))
        XCTAssertEqual(try Data(contentsOf: published), Data("already shared".utf8))
        // Even an index rebuild cannot resurrect a deleted private original or sidecar.
        try fm.removeItem(at: support.appendingPathComponent("index.json"))
        XCTAssertEqual(Set(try launch().entries().map(\.id)), [existing.id, second.id])
    }

    func testDivergentLegacyCopiesKeepBothEditableVersionsAcrossRebuild() throws {
        let base = try folder(), left = base.appendingPathComponent("en"), right = base.appendingPathComponent("zh")
        let support = base.appendingPathComponent("Library")
        var a = EditDocument(name: "Original title", record: record(), revision: UUID())
        _ = try legacyFixture(at: left, document: a, original: image(0.4), categoryID: UUID())
        a.name = "Another title"
        a.revision = UUID()
        a.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 10, height: 12))]
        _ = try legacyFixture(at: right, document: a, original: image(0.4), categoryID: UUID())
        let store = ScrollLibrary(outputFolder: left, root: support, legacyOutputFolders: [left, right])
        let entries = try store.entries()
        XCTAssertEqual(entries.count, 2)
        let before = try XCTUnwrap(entries.first { $0.name == "Original title" })
        let after = try XCTUnwrap(entries.first { $0.name == "Another title" })
        XCTAssertNotEqual(before.id, after.id)
        try FileManager.default.removeItem(at: support.appendingPathComponent("index.json"))
        XCTAssertTrue(try store.load(before.id).document.layers.isEmpty)
        XCTAssertEqual(try store.load(after.id).document.layers, a.layers)
    }

    func testIdenticalLegacyProjectsMergeTheirExportAliasesBeforeRemovingTheDuplicate() throws {
        let base = try folder(), a = base.appendingPathComponent("English"), b = base.appendingPathComponent("中文")
        let support = base.appendingPathComponent("Library"), source = try image(0.5)
        let document = EditDocument(name: "Document", record: record(), revision: UUID())
        let category = UUID()
        let first = try legacyFixture(at: a, document: document, original: source, categoryID: category)
        let second = b.appendingPathComponent(".living-scroll-library")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first.directory, to: second)
        let url = second.appendingPathComponent("index.json")
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(index["entries"] as? [[String: Any]])
        entries[0]["exportedStems"] = ["Other public name"]
        index["entries"] = entries
        try JSONSerialization.data(withJSONObject: index).write(to: url)
        let store = ScrollLibrary(outputFolder: a, root: support, legacyOutputFolders: [a, b])
        XCTAssertEqual(try store.entries().map(\.id), [document.id])
        for name in ["Shared copy", "Other public name"] {
            XCTAssertEqual(try store.entries(matching: name).map(\.id), [document.id])
        }
        try store.delete(document.id)
        let leftovers = try XCTUnwrap(FileManager.default.enumerator(atPath: support.path)).allObjects.compactMap { $0 as? String }
        XCTAssertFalse(leftovers.contains { $0.hasSuffix("original.png") || $0.hasSuffix(".edit.json") })
    }

    func testCorruptIndexIsQuarantinedAndRebuildSkipsUnreadableRevisions() throws {
        let base = try folder(), fm = FileManager.default, store = ScrollLibrary(testDirectory: base)
        let source = try image(0.5)
        var draft = try store.save(EditDocument(name: "Before", record: record()), original: source, categoryID: nil)
        draft.name = "After"
        draft.layers = [EditLayer(kind: .rectangle, rect: CGRect(x: 0, y: 0, width: 12, height: 30))]
        draft = try store.save(draft, original: source, categoryID: nil)
        let project = try store.originalURL(for: draft.id).deletingLastPathComponent()
        try Data("{".utf8).write(to: project.appendingPathComponent(UUID().uuidString + ".edit.json"))
        var mismatch = draft
        mismatch.record.pixelHeight += 1
        mismatch.revision = UUID()
        let badSize = project.appendingPathComponent(try XCTUnwrap(mismatch.revision).uuidString + ".edit.json")
        try JSONEncoder().encode(mismatch).write(to: badSize)
        let support = base.appendingPathComponent("Library"), index = support.appendingPathComponent("index.json")
        let bad = Data("{truncated".utf8)
        try bad.write(to: index)
        XCTAssertEqual(try store.entries().map(\.id), [draft.id])
        let rebuilt = try ScrollLibrary(testDirectory: base).load(draft.id)
        XCTAssertEqual(rebuilt.document.layers, draft.layers)
        XCTAssertEqual(rebuilt.document.revision, draft.revision)
        XCTAssertEqual(rebuilt.document.name, "After")
        let backups = try fm.contentsOfDirectory(atPath: support.path).filter { $0.hasPrefix("index.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(XCTUnwrap(backups.first))), bad)
        XCTAssertEqual(try store.addCategory("Available").name, "Available")
    }

    func testInterruptedFirstCaptureAndInterruptedDeletionAreReconciledOnLaunch() throws {
        let base = try folder(), store = ScrollLibrary(testDirectory: base)
        let support = base.appendingPathComponent("Library"), index = support.appendingPathComponent("index.json")
        try store.prepare()
        let previousIndex = try Data(contentsOf: index)
        let draft = try store.save(EditDocument(name: "Recover me", record: record()), original: image(1), categoryID: nil)
        let project = try store.originalURL(for: draft.id).deletingLastPathComponent()
        try previousIndex.write(to: index)
        XCTAssertEqual(try ScrollLibrary(testDirectory: base).load(draft.id).document.revision, draft.revision)
        let tomb = support.appendingPathComponent(".deleting-" + draft.id.uuidString)
        try FileManager.default.moveItem(at: project, to: tomb)
        XCTAssertTrue(try ScrollLibrary(testDirectory: base).entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tomb.path))
    }

    func testInterruptedEncoderPublishesOnlyACompleteStagedPNG() throws {
        let base = try folder(), store = ScrollLibrary(testDirectory: base), source = try image(0.4)
        try store.prepare()
        let index = base.appendingPathComponent("Library/index.json"), empty = try Data(contentsOf: index)
        let partial = try store.save(EditDocument(name: "Interrupted", record: record()), original: source, categoryID: nil)
        let finished = try store.save(EditDocument(name: "Encoded", record: record()), original: source, categoryID: nil)
        let partialPNG = try store.originalURL(for: partial.id), complete = try store.originalURL(for: finished.id)
        let partialStage = partialPNG.deletingLastPathComponent().appendingPathComponent(".original.pending")
        let completeStage = complete.deletingLastPathComponent().appendingPathComponent(".original.pending")
        let withoutIEND = try Data(contentsOf: partialPNG).dropLast(12)
        try withoutIEND.write(to: partialStage)
        try FileManager.default.removeItem(at: partialPNG)
        // Extra bytes after an imported PNG's end chunk do not corrupt its image.
        var bytes = try Data(contentsOf: complete)
        bytes.append(contentsOf: "trailing bytes".utf8)
        try bytes.write(to: completeStage)
        try FileManager.default.removeItem(at: complete)
        try empty.write(to: index)

        let restarted = ScrollLibrary(testDirectory: base)
        XCTAssertEqual(try restarted.entries().map(\.id), [finished.id])
        XCTAssertEqual(try restarted.load(finished.id).original.height, source.height)
        XCTAssertEqual(try Data(contentsOf: complete), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialPNG.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialStage.path))
    }

    func testUnsupportedIndexIsPreservedForItsWriter() throws {
        let base = try folder(), store = ScrollLibrary(testDirectory: base)
        try store.prepare()
        let index = base.appendingPathComponent("Library/index.json"), future = Data("{\"version\":42}".utf8)
        try future.write(to: index)
        XCTAssertThrowsError(try store.addCategory("Must not downgrade"))
        XCTAssertEqual(try Data(contentsOf: index), future)
    }

    func testUnavailableLegacyLibraryDoesNotBlockPrivateCaptureAutosaveOrOtherMigrations() throws {
        let base = try folder(), blocked = base.appendingPathComponent("First"), good = base.appendingPathComponent("Other")
        let support = base.appendingPathComponent("Library"), source = try image(0.5)
        let legacy = EditDocument(name: "Held", record: record(), revision: UUID())
        let held = try legacyFixture(at: blocked, document: legacy, original: source, categoryID: UUID())
        let url = held.directory.appendingPathComponent("index.json"), compatible = try Data(contentsOf: url)
        let future = Data("{\"version\":17}".utf8)
        try future.write(to: url)
        let other = EditDocument(name: "Readable", record: record(), revision: UUID())
        _ = try legacyFixture(at: good, document: other, original: source, categoryID: UUID())
        func launch() -> ScrollLibrary { ScrollLibrary(outputFolder: good, root: support, legacyOutputFolders: [blocked, good]) }
        let first = launch()
        XCTAssertThrowsError(try first.prepare())
        XCTAssertEqual(try Data(contentsOf: url), future)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.png.path))
        XCTAssertEqual(try first.entries().map(\.id), [other.id])
        var capture = try first.save(EditDocument(name: "New capture", record: record()), original: source, categoryID: nil)
        capture.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 2, y: 2, width: 16, height: 22))]
        capture = try first.save(capture, original: source, categoryID: nil)
        let restarted = launch()
        XCTAssertThrowsError(try restarted.prepare())
        XCTAssertEqual(try restarted.load(capture.id).document.layers, capture.layers)
        XCTAssertEqual(Set(try restarted.entries().map(\.id)), [capture.id, other.id])
        try compatible.write(to: url)
        try restarted.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.directory.path))
        XCTAssertEqual(Set(try restarted.entries().map(\.id)), [capture.id, other.id, legacy.id])
    }

    func testStaleIndexRevisionRepairsOnlyItsRowAndPreservesTheOriginalIndex() throws {
        let base = try folder(), store = ScrollLibrary(testDirectory: base), source = try image(0.2)
        let folder = base.appendingPathComponent("Library"), index = folder.appendingPathComponent("index.json")
        let category = try store.addCategory("Archive")
        let other = try store.save(EditDocument(name: "Also here", record: record()), original: source, categoryID: category.id)
        var doc = try store.save(EditDocument(name: "Revision A", record: record()), original: source, categoryID: category.id)
        try store.recordExport(base.appendingPathComponent("Sent earlier.pdf"), for: doc.id)
        let stale = try Data(contentsOf: index)
        doc.name = "Revision B"
        doc.layers = [EditLayer(kind: .mosaic, rect: CGRect(x: 0, y: 0, width: 20, height: 20))]
        doc = try store.save(doc, original: source, categoryID: category.id)
        try stale.write(to: index)
        let restarted = ScrollLibrary(testDirectory: base)
        let reopened = try restarted.load(doc.id)
        XCTAssertEqual(reopened.document.revision, doc.revision)
        XCTAssertEqual(reopened.document.layers, doc.layers)
        XCTAssertEqual(reopened.categoryID, category.id)
        XCTAssertEqual(try restarted.entries(matching: "Sent earlier").first?.name, "Revision B")
        XCTAssertEqual(try restarted.load(other.id).categoryID, category.id)
        XCTAssertEqual(try restarted.categories(), [category])
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("index.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(XCTUnwrap(quarantined.first))), stale)
    }

    func testMigrationRejectsLinkedContentAndRetriesAfterTheSourceIsFixed() throws {
        let base = try folder(), output = base.appendingPathComponent("Exports")
        let document = EditDocument(name: "Safe", record: record(), revision: UUID())
        let legacy = try legacyFixture(at: output, document: document, original: image(0), categoryID: UUID())
        let external = base.appendingPathComponent("Unrelated"), link = legacy.directory.appendingPathComponent("linked")
        try Data("keep".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let store = ScrollLibrary(testDirectory: base)
        XCTAssertThrowsError(try store.prepare())
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.png.path))
        try FileManager.default.removeItem(at: link)
        try store.prepare()
        XCTAssertEqual(try store.entries().map(\.id), [document.id])
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
    }

    func testIndependentWritersMergeAgainstLatestIndex() throws {
        let root = try folder()
        let count = 12
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: count) { i in
            do { try ScrollLibrary(testDirectory: root).addCategory("Folder \(i)") }
            catch { lock.lock(); failures.append(error); lock.unlock() }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(try ScrollLibrary(testDirectory: root).categories().count, count)
    }

    func testSimultaneousEditsToOneOriginalKeepBothVersions() throws {
        let root = try folder(), source = try image(0.4)
        let first = ScrollLibrary(testDirectory: root), second = ScrollLibrary(testDirectory: root)
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

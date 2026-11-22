import CoreGraphics
import XCTest
@testable import LivingScrollPDF

final class CropSectionTests: XCTestCase {
    private func fixture() throws -> (CGImage, EditDocument) {
        let width = 160, height = 128
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: Stitcher.colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<height {
            ctx.setFillColor(red: CGFloat(row) / 128, green: 0.5, blue: 0.25, alpha: 1)
            ctx.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
        }
        let record = CaptureRecord(appName: "Notes", windowTitle: "Source",
                                   startedAt: Date(timeIntervalSince1970: 500), endedAt: Date(timeIntervalSince1970: 502),
                                   framesStitched: 6, rejoinTruncations: 1, droppedFrames: 2,
                                   pixelWidth: width, pixelHeight: height, pointScale: 2)
        return (try XCTUnwrap(ctx.makeImage()), EditDocument(name: "Notes", record: record))
    }

    func testPrivateOriginalUsesExactRowsAndKeepsEditableCrossingLayersInOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ScrollLibrary(outputFolder: dir.appendingPathComponent("Export"), root: dir.appendingPathComponent("Library"))
        var (image, draft) = try fixture()
        let pen = EditLayer(kind: .pen, rect: CGRect(x: 3, y: 10, width: 65, height: 30),
                            points: [CGPoint(x: 3, y: 10), CGPoint(x: 68, y: 40)], width: 8)
        let mosaic = EditLayer(kind: .mosaic, rect: CGRect(x: 2, y: 45, width: 100, height: 32))
        let text = EditLayer(kind: .text, rect: CGRect(x: 4, y: 38, width: 112, height: 36), text: "Footnote")
        let outside = EditLayer(kind: .mosaic, rect: CGRect(x: 2, y: 60, width: 40, height: 12))
        let touching = EditLayer(kind: .image, rect: CGRect(x: 0, y: 0, width: 50, height: 30))
        let strokeEdge = EditLayer(kind: .pen, rect: CGRect(x: 10, y: 28, width: 40, height: 0),
                                   points: [CGPoint(x: 10, y: 28), CGPoint(x: 50, y: 28)], width: 8)
        draft.layers = [pen, touching, mosaic, outside, text, strokeEdge]
        let category = try library.addCategory("Reference")
        let parent = try library.save(draft, original: image, categoryID: category.id)
        let child = try library.cropSection(of: parent, original: image, rows: 30..<60)
        let saved = try library.load(child.id)
        XCTAssertNotEqual(child.id, parent.id)
        XCTAssertEqual(saved.categoryID, category.id)
        XCTAssertEqual(saved.original.width, image.width)
        XCTAssertEqual(saved.original.height, 30)
        let full = try XCTUnwrap(PixelFrame(cgImage: image))
        let slice = try XCTUnwrap(PixelFrame(cgImage: saved.original))
        XCTAssertTrue(slice.bytes.elementsEqual(full.bytes[(30 * 160 * 4)..<(60 * 160 * 4)]))
        XCTAssertEqual(saved.document.layers.map(\.id), [pen.id, mosaic.id, text.id, strokeEdge.id])
        guard saved.document.layers.count == 4 else { return }
        XCTAssertEqual(saved.document.layers[0].points, [CGPoint(x: 3, y: -20), CGPoint(x: 68, y: 10)])
        XCTAssertEqual(saved.document.layers[1].rect, CGRect(x: 2, y: 15, width: 100, height: 32))
        XCTAssertEqual(saved.document.layers[2].text, "Footnote")
        XCTAssertEqual(saved.document.layers[3].rect.minY, -2)
        XCTAssertEqual(saved.document.record.pixelWidth, 160)
        XCTAssertEqual(saved.document.record.pixelHeight, 30)
        XCTAssertEqual(saved.document.record.croppedFrom, CropSource(id: parent.id, start: 30, end: 60))
        XCTAssertEqual(saved.document.record.appName, parent.record.appName)
        XCTAssertEqual(saved.document.record.windowTitle, parent.record.windowTitle)
        XCTAssertEqual(saved.document.record.startedAt, parent.record.startedAt)
        XCTAssertEqual(saved.document.record.endedAt, parent.record.endedAt)
        XCTAssertEqual(saved.document.record.pointScale, 2)
        XCTAssertEqual(saved.document.record.rejoinTruncations, 1)
        let reloaded = try library.load(parent.id)
        XCTAssertEqual(reloaded.document.layers, draft.layers)
        XCTAssertEqual(reloaded.document.revision, parent.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.outputFolder.path))
    }

    func testNamesAreAllocatedUnderLockAndFollowCurrentParentCategory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ScrollLibrary(outputFolder: dir.appendingPathComponent("Export"), root: dir.appendingPathComponent("Library"))
        let (image, draft) = try fixture()
        let parent = try library.save(draft, original: image, categoryID: nil)
        let category = try library.addCategory("Moved", assigning: [parent.id])
        let other = EditDocument(name: L("Renamed-片段1", "Renamed-Section 1"), record: draft.record)
        try library.save(other, original: image, categoryID: nil)
        try library.rename(id: parent.id, to: "Renamed")
        let lock = NSLock()
        var issues: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 3) { _ in
            do { _ = try library.cropSection(of: parent, original: image, rows: 108..<128) }
            catch { lock.lock(); issues.append(error); lock.unlock() }
        }
        XCTAssertTrue(issues.isEmpty, "\(issues)")
        let children = try library.entries(category: .category(category.id)).filter { $0.id != parent.id }
        XCTAssertEqual(Set(children.map(\.name)), Set((2...4).map { "Renamed" + L("-片段", "-Section ") + String($0) }))
        for child in children {
            XCTAssertEqual(try library.load(child.id).document.record.croppedFrom?.end, 128)
        }
        let full = try library.cropSection(of: parent, original: image, rows: 0..<128)
        XCTAssertEqual(full.record.pixelHeight, image.height)
        for invalid in [0..<0, 0..<19, -1..<24, 100..<129] {
            XCTAssertThrowsError(try library.cropSection(of: parent, original: image, rows: invalid))
        }
        XCTAssertEqual(try library.entries().count, 6)
    }

    func testCropSourceRoundTripAndLegacyRecordWithoutIt() throws {
        let (_, draft) = try fixture()
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let legacy = try encoder.encode(draft.record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertNil(object["croppedFrom"])
        XCTAssertNil(try decoder.decode(CaptureRecord.self, from: legacy).croppedFrom)
        var record = draft.record
        record.croppedFrom = CropSource(id: draft.id, start: 0, end: 20)
        let decoded = try decoder.decode(CaptureRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded.croppedFrom, record.croppedFrom)
    }

    func testRetryAfterIndexWriteFailsOnlyPublishesOneSection() throws {
        let fm = FileManager.default, base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("Library"), output = base.appendingPathComponent("Export")
        let library = ScrollLibrary(outputFolder: output, root: root)
        let (image, draft) = try fixture()
        let parent = try library.save(draft, original: image, categoryID: nil)
        // The private project directory remains writable, but replacing the index fails.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try library.cropSection(of: parent, original: image, rows: 0..<30))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let retry = try library.cropSection(of: parent, original: image, rows: 0..<30)
        let reopened = ScrollLibrary(outputFolder: output, root: root)
        XCTAssertEqual(Set(try reopened.entries().map(\.id)), Set([parent.id, retry.id]))
        XCTAssertEqual(retry.name, L("Notes-片段1", "Notes-Section 1"))
    }

    func testChangedMasksInAnotherWindowRequireReopeningBeforeCropping() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Library"), output = base.appendingPathComponent("Export")
        let viewer = ScrollLibrary(outputFolder: output, root: root)
        let writer = ScrollLibrary(outputFolder: output, root: root)
        let (image, draft) = try fixture()
        let mask = EditLayer(kind: .mosaic, rect: CGRect(x: 5, y: 15, width: 90, height: 50))
        for changed in [[], [mask.translated(dx: 0, dy: 60)]] {
            var source = draft
            source.id = UUID()
            source.layers = [mask]
            let visible = try viewer.save(source, original: image, categoryID: nil)
            var elsewhere = try writer.load(visible.id).document
            elsewhere.layers = changed
            try writer.save(elsewhere, original: image, categoryID: nil)
            let ids = try viewer.entries().map(\.id)
            XCTAssertThrowsError(try viewer.cropSection(of: visible, original: image, rows: 20..<60))
            XCTAssertEqual(try viewer.entries().map(\.id), ids)
            let reopened = try viewer.load(visible.id)
            let child = try viewer.cropSection(of: reopened.document, original: reopened.original, rows: 20..<60)
            XCTAssertTrue(child.layers.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testDevelopmentMembershipSwitchHasOneEnvironmentOverride() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(Membership.allows(.cropSection, defaults: defaults, environment: [:]))
        defaults.set(false, forKey: "membershipActive")
        XCTAssertFalse(Membership.allows(.cropSection, defaults: defaults, environment: [:]))
        XCTAssertTrue(Membership.allows(.cropSection, defaults: defaults, environment: ["LSP_MEMBERSHIP_ACTIVE": "1"]))
        defaults.set(true, forKey: "membershipActive")
        XCTAssertFalse(Membership.allows(.cropSection, defaults: defaults, environment: ["LSP_MEMBERSHIP_ACTIVE": "0"]))
    }
}

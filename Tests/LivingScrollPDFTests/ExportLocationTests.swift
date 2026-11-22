import CoreGraphics
import XCTest
@testable import LivingScrollPDF

final class ExportLocationTests: XCTestCase {
    private let fm = FileManager.default
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let suite = "ExportLocationTests." + UUID().uuidString
    private var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    private var desktop: URL { root.appendingPathComponent("Desktop", isDirectory: true) }
    private var chosen: URL { root.appendingPathComponent("My Exports", isDirectory: true) }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        if fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func destination(_ environment: [String: String] = [:]) -> ExportDestination {
        ExportDestination.current(defaults: defaults, environment: environment, desktop: desktop)
    }

    private func fixture() throws -> (EditDocument, CGImage) {
        let context = try XCTUnwrap(CGContext(data: nil, width: 12, height: 16, bitsPerComponent: 8,
            bytesPerRow: 48, space: Stitcher.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let record = CaptureRecord(appName: "Fixture", windowTitle: "", startedAt: Date(), endedAt: Date(),
                                   framesStitched: 1, droppedFrames: 0, pixelWidth: 12, pixelHeight: 16, pointScale: 1)
        return (EditDocument(name: "Trip", record: record), try XCTUnwrap(context.makeImage()))
    }

    func testPickerChoiceSurvivesNewDefaultsAndChangesAnOpenLibraryImmediately() throws {
        let library = ScrollLibrary(root: root.appendingPathComponent("Library"), exportDestination: { self.destination() })
        let (document, image) = try fixture()
        let saved = try library.save(document, original: image, categoryID: nil)
        let old = try EditorExport.write(saved, original: image, to: library.exportDestination)
        let oldHash = try Exporter.sha256(of: old.pdf)
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        ExportDestination.setCustomFolder(chosen, defaults: defaults)
        XCTAssertEqual(destination().customFolder, chosen)
        XCTAssertEqual(library.outputFolder, chosen)
        XCTAssertEqual(library.legacyOutputFolders, destination().legacyFolders)
        XCTAssertEqual(destination().recoveryFolders, [chosen] + library.legacyOutputFolders)

        // A matching earlier Desktop export must not redirect the new selection.
        let result = try EditorExport.write(saved, original: image, to: library.exportDestination)
        XCTAssertFalse(result.usedDesktopFallback)
        XCTAssertEqual(result.files, ["Trip.png", "Trip.pdf"].map { chosen.appendingPathComponent($0) })
        XCTAssertTrue(result.files.allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(fm.fileExists(atPath: chosen.appendingPathComponent("Trip.json").path))
        XCTAssertEqual(try Exporter.sha256(of: old.pdf), oldHash)
        XCTAssertEqual(try library.load(saved.id).document.id, saved.id)

        ExportDestination.setCustomFolder(nil, defaults: defaults)
        XCTAssertNil(destination().customFolder)
        XCTAssertEqual(library.outputFolder, old.folder)
        XCTAssertTrue(result.files.allSatisfy { fm.fileExists(atPath: $0.path) })
    }

    func testDeletedDestinationFallsBackWithoutRecreatingItAndWorksWhenReconnected() throws {
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        ExportDestination.setCustomFolder(chosen, defaults: defaults)
        let location = destination()
        let (document, image) = try fixture()
        try fm.removeItem(at: chosen)
        XCTAssertEqual(location.folder, location.defaultFolder)
        let result = try EditorExport.write(document, original: image, to: location)
        XCTAssertTrue(result.usedDesktopFallback)
        XCTAssertEqual(result.folder, location.defaultFolder)
        XCTAssertEqual(result.files.map(\.pathExtension), ["png", "pdf"])
        XCTAssertTrue(result.files.allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertFalse(fm.fileExists(atPath: chosen.path))
        XCTAssertEqual(destination().customFolder, chosen)
        XCTAssertTrue(PendingCustomExports(defaults: defaults).entries.isEmpty)

        try fm.createDirectory(at: chosen, withIntermediateDirectories: false)
        let next = try EditorExport.write(document, original: image, to: destination())
        XCTAssertEqual(next.folder, chosen)
        XCTAssertFalse(next.usedDesktopFallback)
    }

    func testReadOnlyDestinationFallsBackWithBothFiles() throws {
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: chosen.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: chosen.path) }
        ExportDestination.setCustomFolder(chosen, defaults: defaults)
        let (document, image) = try fixture()
        let result = try EditorExport.write(document, original: image, to: destination())
        XCTAssertTrue(result.usedDesktopFallback)
        XCTAssertEqual(result.folder, destination().defaultFolder)
        XCTAssertTrue(result.files.allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: chosen.path).isEmpty)
    }

    func testChosenFolderRefusesPublicationAfterPreflight() throws {
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        let occupied = chosen.appendingPathComponent(".living-scroll-export")
        let personal = Data("occupied".utf8)
        try personal.write(to: occupied)
        ExportDestination.setCustomFolder(chosen, defaults: defaults)
        let location = destination()
        XCTAssertEqual(location.folder, chosen)
        let (document, image) = try fixture()
        let result = try EditorExport.write(document, original: image, to: location)
        XCTAssertTrue(result.usedDesktopFallback)
        XCTAssertEqual(result.folder, location.defaultFolder)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(CaptureRecord.self, from: Data(contentsOf: result.folder.appendingPathComponent("Trip.json")))
        XCTAssertEqual(record.pngSHA256, try Exporter.sha256(of: result.png))
        XCTAssertEqual(record.pdfSHA256, try Exporter.sha256(of: result.pdf))
        XCTAssertEqual(try Data(contentsOf: occupied), personal)
    }

    func testEnvironmentOverrideWinsAndStillCreatesItsOutputDirectory() throws {
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        ExportDestination.setCustomFolder(chosen, defaults: defaults)
        let override = root.appendingPathComponent("Automation", isDirectory: true)
        let location = destination(["JZ_OUT": override.path])
        XCTAssertEqual(location.folder, override)
        XCTAssertEqual(location.recoveryFolders, [override])
        let (document, image) = try fixture()
        let result = try EditorExport.write(document, original: image, to: location)
        XCTAssertEqual(result.folder, override)
        XCTAssertFalse(result.usedDesktopFallback)
        XCTAssertTrue(result.files.allSatisfy { fm.fileExists(atPath: $0.path) })
        XCTAssertEqual(destination().folder, chosen)
    }

    func testUnsetPreferenceKeepsTheHistoricalDesktopChoiceAndRecoveryOrder() throws {
        let preferred = L("卷轴PDF", "Living Scroll PDF")
        let other = preferred == "卷轴PDF" ? "Living Scroll PDF" : "卷轴PDF"
        let historic = desktop.appendingPathComponent(other, isDirectory: true)
        try fm.createDirectory(at: historic, withIntermediateDirectories: true)
        let previous = Exporter.desktopFolders(in: desktop, preferredName: preferred, savedName: nil)
        XCTAssertEqual(destination().folder, historic)
        XCTAssertEqual(destination().legacyFolders, previous)
        XCTAssertEqual(destination().recoveryFolders, previous)
        XCTAssertEqual(defaults.string(forKey: "desktopExportFolderName"), other)
        try fm.createDirectory(at: desktop.appendingPathComponent(preferred), withIntermediateDirectories: true)
        XCTAssertEqual(destination().folder, historic)
    }
}

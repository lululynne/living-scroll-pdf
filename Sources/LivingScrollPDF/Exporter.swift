import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pixel rows in the immediate parent, counted from the top. The end row is exclusive.
struct CropSource: Codable, Equatable {
    static let minimumHeight = 20
    let id: UUID
    let start: Int
    let end: Int
}

struct CaptureRecord: Codable {
    var tool = "卷轴PDF · Living Scroll PDF \(Exporter.version)"
    var appName: String
    /// Private projects retain the title; public records keep an empty string for older readers.
    var windowTitle: String
    var startedAt: Date
    var endedAt: Date
    var framesStitched: Int
    /// Number of times a verified return replaced a divergent suffix. Absent in older projects.
    var rejoinTruncations: Int? = nil
    /// Frames dropped because they could not be placed; the image has no seams.
    var droppedFrames: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var pointScale: Double
    var pdfPages: Int = 0
    var pngSHA256: String = ""
    var pdfSHA256: String = ""
    /// The capture ended while the last frame could not be placed: content is missing at the end.
    var isPartial = false
    var partialReason: String? = nil
    /// Where the image stops being a continuous capture. Nil, and omitted from JSON, when it does not.
    var gaps: [ContentGap]? = nil
    /// A local library reference allows a flattened export to reopen with its original layers.
    var editingProjectID: UUID? = nil
    var editLayerCount: Int? = nil
    var croppedFrom: CropSource? = nil
}

/// A stretch that was on screen and is not in the image. `afterRow` is the image height:
/// the missing rows are after the last row that was proved to follow the one above it.
struct ContentGap: Codable, Equatable {
    var afterRow: Int
    var droppedFrames: Int
    var reason: String
}

enum Exporter {
    /// A packaged app records CFBundleShortVersionString. `dev` is only the command-line
    /// binary, which has no app bundle; it must not be written up as 0.1.0. A bare `1.0`
    /// from an unrelated bundle is not a release of this app either.
    static func releaseVersion(bundleShort: String?, bundleIdentifier: String?) -> String {
        let packaged = bundleIdentifier == "io.github.lululynne.livingscrollpdf"
        if let raw = bundleShort?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if packaged { return raw }
            if raw != "1.0" { return raw }
        }
        return "dev"
    }

    static var version: String {
        releaseVersion(
            bundleShort: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    enum PDFLayout: String {
        /// One tall page, like the PNG; split only where a page would exceed the PDF size limit.
        case long
        /// A4-proportioned pages, for printing.
        case a4
    }

    static var pdfLayout: PDFLayout {
        get { PDFLayout(rawValue: UserDefaults.standard.string(forKey: "pdfLayout") ?? "") ?? .long }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pdfLayout") }
    }

    /// 200 inches: the largest page Acrobat and most viewers accept.
    static let maxPagePoints = 14_400
    static let maxStemBytes = 220

    static var outputFolder: URL { ExportDestination.current().folder }
    static var outputFolders: [URL] { ExportDestination.current().recoveryFolders }

    static func desktopFolders(in desktop: URL, preferredName: String, savedName: String?) -> [URL] {
        let folders = ["Living Scroll PDF", "卷轴PDF"].map { desktop.appendingPathComponent($0, isDirectory: true) }
        let fm = FileManager.default
        let primary = folders.first { $0.lastPathComponent == savedName }
            ?? folders.first { fm.fileExists(atPath: $0.appendingPathComponent(".living-scroll-library/index.json").path) }
            ?? folders.first { $0.lastPathComponent == preferredName && fm.fileExists(atPath: $0.path) }
            ?? folders.first { fm.fileExists(atPath: $0.path) }
            ?? folders.first { $0.lastPathComponent == preferredName } ?? folders[0]
        return [primary] + folders.filter { $0 != primary }
    }

    static func fileStem(for record: CaptureRecord, name: String? = nil) -> String {
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        var supplied = name?.trimmingCharacters(in: trim) ?? ""
        if supplied.isEmpty {
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyyMMdd-HHmmss"
            supplied = L("卷轴PDF", "LivingScrollPDF") + "-\(record.appName)-\(stamp.string(from: record.endedAt))"
        }
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        var cleaned = supplied.components(separatedBy: unsafe).joined(separator: "-")
        var partialSuffix = ""
        if record.isPartial {
            // Older names can have 220 bytes followed by a marker in either language.
            if let marker = ["-未完成", "-partial"].first(where: { cleaned.suffix($0.count).lowercased() == $0 }) {
                partialSuffix = String(cleaned.suffix(marker.count))
                cleaned.removeLast(marker.count)
            } else if name == nil {
                partialSuffix = L("-未完成", "-partial")
            }
        }
        var stem = ""
        for character in cleaned {
            if stem.utf8.count + String(character).utf8.count > maxStemBytes { break }
            stem.append(character)
        }
        if stem.isEmpty && !cleaned.isEmpty { stem = L("长截图", "Screenshot") }
        return stem + partialSuffix
    }

    /// Encode all of the new products before replacing any public file.
    static func export(_ image: CGImage, record: CaptureRecord, folder: URL,
                       name: String? = nil, layers: [EditLayer] = [], layout: PDFLayout = pdfLayout,
                       legacyFolders: [URL] = []) throws -> URL {
        try export(image, record: record, to: ExportDestination(defaultFolder: folder, legacyFolders: legacyFolders),
                   name: name, layers: layers, layout: layout).pdf
    }

    static func export(_ image: CGImage, record: CaptureRecord, to destination: ExportDestination,
                       name: String? = nil, layers: [EditLayer] = [], layout: PDFLayout = pdfLayout) throws -> ExportedFiles {
        destination.pendingExports?.recoverAvailable()
        let stem = fileStem(for: record, name: name)
        let render = { (png: URL, pdf: URL, json: URL) throws in
            let pages = try BandedExport.write(original: image, layers: layers, record: record,
                                               layout: layout, png: png, pdf: pdf)
            var published = record
            published.windowTitle = ""
            published.pdfPages = pages
            published.pngSHA256 = try sha256(of: png)
            published.pdfSHA256 = try sha256(of: pdf)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(published).write(to: json)
        }

        let folder: URL
        if destination.customFolder != nil {
            // Even after the preflight, a removable disk can disappear or refuse the actual write.
            // Retry the whole transaction on Desktop, retaining the chosen path for its next mount.
            if let chosen = destination.usableCustomFolder,
               let pdf = try? ExportPublication.write(in: chosen, createFolder: false, tracking: destination.pendingExports, stem: stem,
                                                      projectID: record.editingProjectID, render: render) {
                return ExportedFiles(pdf: pdf, usedDesktopFallback: false)
            }
            folder = destination.defaultFolder
        } else {
            folder = ExportPublication.previousFolder(for: record.editingProjectID, stem: stem,
                                                      preferred: destination.defaultFolder, legacyFolders: destination.legacyFolders)
        }
        let pdf = try ExportPublication.write(in: folder, stem: stem, projectID: record.editingProjectID, render: render)
        let unfinished = destination.customFolder.map { destination.pendingExports?.entries.values.contains($0) == true } ?? false
        return ExportedFiles(pdf: pdf, usedDesktopFallback: destination.customFolder != nil, unfinishedAtCustomFolder: unfinished)
    }

    static func recoverPendingExport(in folder: URL) throws {
        _ = try ExportPublication.recoverPending(in: folder)
    }

    /// Hex-encoded UTF-16BE is a PDF text string even for emoji, CJK, or literal delimiters.
    static func pdfInfoObject(for record: CaptureRecord) -> String {
        let title = record.appName.utf16.map { String(format: "%04X", $0) }.joined()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return "<< /Title <FEFF\(title)> /CreationDate (D:\(formatter.string(from: record.endedAt))Z) >>"
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreate(url)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotCreate(url) }
    }

    static func pageHeight(_ image: CGImage, scale: Double, layout: PDFLayout) -> Int {
        switch layout {
        case .long:
            // A very large scale in an imported record still fits on one page.
            let maxRows = Double(maxPagePoints) * max(scale.isFinite ? scale : 1, 1)
            return Int(min(Double(image.height), maxRows))
        case .a4: return max(200, Int(Double(image.width) * 1.414))
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var finished = false
        while !finished {
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    finished = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum ExportError: LocalizedError, CustomStringConvertible {
        case cannotCreate(URL)
        case interrupted(URL)
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .cannotCreate(let url): return L("无法写入 \(url.path)", "Could not write \(url.path)")
            case .interrupted(let url): return L("中断导出的剩余文件保存在 \(url.path)", "The remaining files from the interrupted export are in \(url.path)")
            }
        }
    }
}

/// Each ready transaction gets its own key. A later export or another process can
/// finish one generation without clearing a newer writer's recovery location.
struct PendingCustomExports {
    let defaults: UserDefaults
    private let prefix = "pendingCustomExport."

    var entries: [String: URL] {
        var result: [String: URL] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let path = value as? String { result[key] = URL(fileURLWithPath: path, isDirectory: true) }
        }
        return result
    }

    func remember(_ folder: URL) -> String {
        let key = prefix + UUID().uuidString
        defaults.set(folder.path, forKey: key)
        return key
    }

    func recoverAvailable() {
        for (key, folder) in entries {
            if (try? ExportPublication.recoverPending(in: folder)) == true { defaults.removeObject(forKey: key) }
        }
    }
}

/// The directory inode is the cross-process lock. A prepared transaction contains only
/// the new public files. After a crash, the next writer finishes any remaining renames.
/// The JSON hashes are published last; readers can verify the pair they opened.
private enum ExportPublication {
    private static let extensions = ["png", "pdf", "json"]
    private static let owner = ".living-scroll-publication-v1"
    private static let exchange = ".exchange.json"
    private static let retiredPrefix = ".living-scroll-export-done-"
    private static let stagingFiles = Set(extensions.flatMap { ["output." + $0, "prepared." + $0] }
        + [owner, exchange, ".copying", ".exchange.pending"])

    private struct FileVersion: Codable, Equatable {
        let device: dev_t, inode: ino_t, size: off_t
        let modifiedSeconds: Int, modifiedNanoseconds: Int

        init(_ state: stat) {
            device = state.st_dev
            inode = state.st_ino
            size = state.st_size
            modifiedSeconds = state.st_mtimespec.tv_sec
            modifiedNanoseconds = state.st_mtimespec.tv_nsec
        }
    }

    private struct Exchange: Codable {
        let ext: String
        let previous: FileVersion
        let incoming: FileVersion
    }

    private struct Identity: Decodable {
        let editingProjectID: UUID?
        let pngSHA256: String
        let pdfSHA256: String

        static func read(at url: URL, state: stat?) -> Self? {
            guard let state, state.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }

        func matches(_ url: URL) -> Bool {
            let expected = url.pathExtension == "png" ? pngSHA256 : pdfSHA256
            return (try? Exporter.sha256(of: url)) == expected
        }
    }

    private struct Destination {
        let stem: String
        /// Only these existing files have been verified against this project's public record.
        let replacing: [String: stat]
    }

    /// A previous app language may have selected the other Desktop folder. Only follow a
    /// complete matching export there, including one that was assigned a numbered filename.
    static func previousFolder(for id: UUID?, stem: String, preferred: URL, legacyFolders: [URL]) -> URL {
        let alternatives = legacyFolders.filter { $0 != preferred }
        guard let id, !alternatives.isEmpty else { return preferred }
        guard let legacy = alternatives.first(where: {
            (try? existingDestination(named: stem, in: $0, projectID: id, requireComplete: true)) != nil
        }) else { return preferred }
        return (try? existingDestination(named: stem, in: preferred, projectID: id)) == nil ? legacy : preferred
    }

    static func write(in folder: URL, createFolder: Bool = true, tracking: PendingCustomExports? = nil, stem: String, projectID: UUID?,
                      render: (URL, URL, URL) throws -> Void) throws -> URL {
        if createFolder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return try withOutputLock(in: folder) {
            let stage = stagingDirectory(in: folder)
            do { try recover(stage: stage, in: folder) }
            catch Exporter.ExportError.interrupted { /* The incomplete v1 set has been kept separately. */ }
            return try write(stem: stem, projectID: projectID, in: folder, stage: stage, tracking: tracking, render: render)
        }
    }

    static func recoverPending(in folder: URL) throws -> Bool {
        guard try attributes(of: folder) != nil else { return false }
        try withOutputLock(in: folder) { try recover(stage: stagingDirectory(in: folder), in: folder) }
        return true
    }

    private static func withOutputLock<T>(in folder: URL, _ action: () throws -> T) throws -> T {
        let fd = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError() }
        }
        return try action()
    }

    private static func stagingDirectory(in folder: URL) -> URL {
        folder.appendingPathComponent(".living-scroll-export", isDirectory: true)
    }

    private static func write(stem: String, projectID: UUID?, in folder: URL, stage: URL,
                              tracking: PendingCustomExports?, render: (URL, URL, URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer {
            // After marking the staged set ready, retain any unpublished products for retry.
            if !prepared { try? discard(stage: stage, in: folder) }
        }
        try Data().write(to: stage.appendingPathComponent(owner))
        let png = stage.appendingPathComponent("output.png")
        let pdf = stage.appendingPathComponent("output.pdf")
        let json = stage.appendingPathComponent("output.json")
        try render(png, pdf, json)
        let target = try destination(named: stem, in: folder, projectID: projectID)
        try validateDestinations(stem: target.stem, folder: folder)
        for ext in extensions {
            try copyProduct(stage.appendingPathComponent("output." + ext), to: stage.appendingPathComponent("prepared." + ext))
        }
        try Data(stem.utf8).write(to: stage.appendingPathComponent(target.stem + ".ready"))
        prepared = true
        let pendingKey = tracking?.remember(folder)
        let publishedStem: String
        do {
            try publish(stage: stage, target: target, folder: folder)
            publishedStem = target.stem
        } catch let error as POSIXError where error.code == .EEXIST {
            publishedStem = try resumePublication(stem: target.stem, stage: stage, folder: folder)
        }
        try discard(stage: stage, in: folder)
        if let pendingKey { tracking?.defaults.removeObject(forKey: pendingKey) }
        return folder.appendingPathComponent(publishedStem + ".pdf")
    }

    private static func validStagingNames(_ names: [String]) -> Bool {
        names.filter { $0.hasSuffix(".ready") }.count <= 1
            && names.allSatisfy { stagingFiles.contains($0) || $0.hasSuffix(".ready") }
    }

    private static func discard(stage: URL, in folder: URL) throws {
        // Free the active name before unlinking anything, including its ownership marker.
        let retired = folder.appendingPathComponent(retiredPrefix + UUID().uuidString)
        guard renamex_np(stage.path, retired.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
        removeRetiredStage(retired)
    }

    private static func removeRetiredStage(_ directory: URL) {
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              validStagingNames(names) else { return }
        // Remove only the expected regular files. A newly added file keeps the directory alive.
        for name in names {
            var state = stat()
            if fstatat(fd, name, &state, AT_SYMLINK_NOFOLLOW) == 0 && state.st_mode & S_IFMT == S_IFREG {
                _ = unlinkat(fd, name, 0)
            }
        }
        _ = rmdir(directory.path)
    }

    private static func recover(stage: URL, in folder: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: folder.path) where name.hasPrefix(retiredPrefix) {
            if UUID(uuidString: String(name.dropFirst(retiredPrefix.count))) != nil {
                removeRetiredStage(folder.appendingPathComponent(name))
            }
        }
        guard let state = try attributes(of: stage) else { return }
        guard state.st_mode & S_IFMT == S_IFDIR else { throw Exporter.ExportError.cannotCreate(stage) }
        let names = try fm.contentsOfDirectory(atPath: stage.path)
        if !names.isEmpty {
            // A reserved name occupied by unrelated files must survive an export attempt.
            guard names.contains(owner), validStagingNames(names) else {
                throw Exporter.ExportError.cannotCreate(stage)
            }
            if let marker = names.first(where: { $0.hasSuffix(".ready") }) {
                let stem = String(marker.dropLast(".ready".count))
                guard !stem.isEmpty, stem != ".", stem != ".." else {
                    throw Exporter.ExportError.cannotCreate(stage)
                }
                // JSON is renamed last. A leftover marker alone means publication finished.
                if names.contains(exchange) || extensions.contains(where: { names.contains("output." + $0) }) {
                    _ = try resumePublication(stem: stem, stage: stage, folder: folder)
                }
            }
        }
        // An interrupted encoder has no ready marker and has never touched public files.
        try discard(stage: stage, in: folder)
    }

    private static func resumePublication(stem: String, stage: URL, folder: URL) throws -> String {
        let journal = stage.appendingPathComponent(exchange)
        if let state = try attributes(of: journal) {
            guard state.st_mode & S_IFMT == S_IFREG else { throw Exporter.ExportError.cannotCreate(journal) }
            let operation = try JSONDecoder().decode(Exchange.self, from: Data(contentsOf: journal))
            guard extensions.contains(operation.ext) else { throw Exporter.ExportError.cannotCreate(stage) }
            _ = try finishExchange(operation, stage: stage, stem: stem, folder: folder)
        }
        let marker = stage.appendingPathComponent(stem + ".ready")
        guard let markerState = try attributes(of: marker), markerState.st_mode & S_IFMT == S_IFREG,
              markerState.st_size <= NAME_MAX else { throw Exporter.ExportError.cannotCreate(marker) }
        let saved = try String(contentsOf: marker, encoding: .utf8)
        // Empty v1 markers used the requested name verbatim. New markers also remember the
        // original stem so an interrupted "-2" can move to "-3" if its target has changed.
        let base = saved.isEmpty ? stem : saved
        guard stem == base || (stem.hasPrefix(base + "-") && Int(stem.dropFirst(base.count + 1)) != nil) else {
            throw Exporter.ExportError.cannotCreate(marker)
        }
        let json = stage.appendingPathComponent("output.json")
        if try attributes(of: json) == nil {
            for ext in ["png", "pdf"] where try attributes(of: stage.appendingPathComponent("output." + ext)) != nil {
                throw Exporter.ExportError.cannotCreate(json)
            }
            return stem // The last rename completed before cleanup.
        }
        guard let incoming = Identity.read(at: json, state: try attributes(of: json)) else {
            throw Exporter.ExportError.cannotCreate(json)
        }
        var moved = Set<String>()
        for ext in ["png", "pdf"] {
            let source = stage.appendingPathComponent("output." + ext)
            guard try attributes(of: source) == nil else { continue }
            let file = folder.appendingPathComponent(stem + "." + ext)
            if let state = try attributes(of: file), state.st_mode & S_IFMT == S_IFREG, incoming.matches(file) {
                moved.insert(ext)
            } else {
                let prepared = stage.appendingPathComponent("prepared." + ext)
                guard let copy = try attributes(of: prepared), copy.st_mode & S_IFMT == S_IFREG else {
                    // Older writers kept no second copy after a rename.
                    let retained = folder.appendingPathComponent(".living-scroll-interrupted-" + UUID().uuidString)
                    try FileManager.default.moveItem(at: stage, to: retained)
                    throw Exporter.ExportError.interrupted(retained)
                }
                try copyProduct(prepared, to: source)
            }
        }
        let target = try matchingDestination(stem, in: folder, projectID: incoming.editingProjectID, moved: moved)
            ?? destination(named: base, in: folder, projectID: incoming.editingProjectID)
        try validateDestinations(stem: target.stem, folder: folder)
        if target.stem != stem {
            let fm = FileManager.default
            for ext in moved {
                let prepared = stage.appendingPathComponent("prepared." + ext)
                let source = try attributes(of: prepared) == nil ? folder.appendingPathComponent(stem + "." + ext) : prepared
                try copyProduct(source, to: stage.appendingPathComponent("output." + ext))
            }
            if saved.isEmpty { try Data(base.utf8).write(to: marker, options: .atomic) }
            try fm.moveItem(at: marker, to: stage.appendingPathComponent(target.stem + ".ready"))
        }
        try publish(stage: stage, target: target, folder: folder)
        return target.stem
    }

    private static func copyProduct(_ source: URL, to target: URL) throws {
        // APFS clones keep the staged generation independent of edits to a newly public file.
        if clonefile(source.path, target.path, 0) == 0 { return }
        let fm = FileManager.default, temporary = target.deletingLastPathComponent().appendingPathComponent(".copying")
        if try attributes(of: temporary) != nil { try fm.removeItem(at: temporary) }
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
    }

    private static func matchingDestination(_ name: String, in folder: URL, projectID: UUID?,
                                            moved: Set<String> = [], requireComplete: Bool = false) throws -> Destination? {
        let json = folder.appendingPathComponent(name + ".json")
        let jsonState = try attributes(of: json)
        let prior = Identity.read(at: json, state: jsonState)
        var replacing: [String: stat] = [:]
        if let jsonState {
            guard let projectID, prior?.editingProjectID == projectID else { return nil }
            replacing["json"] = jsonState
        } else if moved.isEmpty { return nil }
        for ext in ["png", "pdf"] where !moved.contains(ext) {
            let url = folder.appendingPathComponent(name + "." + ext)
            if let state = try attributes(of: url) {
                guard state.st_mode & S_IFMT == S_IFREG, prior?.matches(url) == true else { return nil }
                replacing[ext] = state
            } else if requireComplete { return nil }
        }
        return Destination(stem: name, replacing: replacing)
    }

    private static func existingDestination(named stem: String, in folder: URL, projectID: UUID?,
                                            requireComplete: Bool = false) throws -> Destination? {
        guard let projectID else { return nil }
        if let base = try matchingDestination(stem, in: folder, projectID: projectID, requireComplete: requireComplete) { return base }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let suffixes = names.compactMap { name -> Int? in
            guard name.lowercased().hasSuffix(".json"),
                  let prefix = name.range(of: stem + "-", options: [.anchored, .caseInsensitive]),
                  let number = Int(name[prefix.upperBound...].dropLast(5)), number >= 2 else { return nil }
            return number
        }
        for number in suffixes.sorted() {
            if let existing = try matchingDestination(stem + "-\(number)", in: folder, projectID: projectID,
                                                      requireComplete: requireComplete) { return existing }
        }
        return nil
    }

    private static func destination(named stem: String, in folder: URL, projectID: UUID?) throws -> Destination {
        if let existing = try existingDestination(named: stem, in: folder, projectID: projectID) {
            return existing
        }
        var name = stem, suffix = 2
        while try extensions.contains(where: { try attributes(of: folder.appendingPathComponent(name + "." + $0)) != nil }) {
            name = stem + "-\(suffix)"
            suffix += 1
        }
        return Destination(stem: name, replacing: [:])
    }

    private static func validateDestinations(stem: String, folder: URL) throws {
        for ext in extensions {
            let url = folder.appendingPathComponent(stem + "." + ext)
            guard let state = try attributes(of: url) else { continue }
            let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
            guard state.st_mode & S_IFMT == S_IFREG, state.st_flags & locked == 0 else {
                throw Exporter.ExportError.cannotCreate(url)
            }
        }
    }

    private static func publish(stage: URL, target: Destination, folder: URL) throws {
        for ext in extensions {
            let source = stage.appendingPathComponent("output." + ext)
            let file = folder.appendingPathComponent(target.stem + "." + ext)
            let staged = try attributes(of: source)
            let product = staged == nil ? file : source
            guard let state = try staged ?? attributes(of: file), state.st_mode & S_IFMT == S_IFREG else {
                throw Exporter.ExportError.cannotCreate(product)
            }
            if state.st_mode & 0o7777 != 0o644 {
                guard fchmodat(AT_FDCWD, product.path, 0o644, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError() }
            }
            guard staged != nil else { continue }
            if let checked = target.replacing[ext], let current = try attributes(of: file) {
                guard current.st_dev == checked.st_dev, current.st_ino == checked.st_ino,
                      current.st_ctimespec.tv_sec == checked.st_ctimespec.tv_sec,
                      current.st_ctimespec.tv_nsec == checked.st_ctimespec.tv_nsec else { throw POSIXError(.EEXIST) }
                let operation = Exchange(ext: ext, previous: FileVersion(checked), incoming: FileVersion(state))
                let journal = stage.appendingPathComponent(exchange)
                let pending = stage.appendingPathComponent(".exchange.pending")
                try JSONEncoder().encode(operation).write(to: pending)
                guard renamex_np(pending.path, journal.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
                guard renamex_np(source.path, file.path, UInt32(RENAME_SWAP)) == 0 else {
                    let error = posixError()
                    try FileManager.default.removeItem(at: journal)
                    throw error.code == .ENOENT ? POSIXError(.EEXIST) : error
                }
                guard try finishExchange(operation, stage: stage, stem: target.stem, folder: folder) else { throw POSIXError(.EEXIST) }
            } else {
                guard renamex_np(source.path, file.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            }
        }
    }

    /// Swap keeps the displaced inode until it can be checked. An ordinary replacing
    /// rename would unlink a Finder save that raced the final lstat.
    private static func finishExchange(_ operation: Exchange, stage: URL, stem: String, folder: URL) throws -> Bool {
        let fm = FileManager.default
        let source = stage.appendingPathComponent("output." + operation.ext)
        let file = folder.appendingPathComponent(stem + "." + operation.ext)
        let displaced = try attributes(of: source).map(FileVersion.init)
        var finished = displaced == nil
        if displaced == nil, try attributes(of: file).map(FileVersion.init) != operation.incoming {
            try copyProduct(stage.appendingPathComponent("prepared." + operation.ext), to: source)
            finished = false
        } else if displaced == operation.previous {
            try fm.removeItem(at: source)
            finished = true
        } else if let displaced, displaced != operation.incoming {
            let publicFile = try attributes(of: file).map(FileVersion.init)
            if publicFile == operation.incoming {
                guard renamex_np(source.path, file.path, UInt32(RENAME_SWAP)) == 0 else { throw posixError() }
            } else if publicFile == nil {
                guard renamex_np(source.path, file.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError() }
            }
            if let remaining = try attributes(of: source), FileVersion(remaining) != operation.incoming {
                // A second independent save also won the name. Keep both personal files.
                let kept = folder.appendingPathComponent("Recovered-" + UUID().uuidString + "." + operation.ext)
                try fm.moveItem(at: source, to: kept)
            }
            if try attributes(of: source) == nil {
                try copyProduct(stage.appendingPathComponent("prepared." + operation.ext), to: source)
            }
        }
        try fm.removeItem(at: stage.appendingPathComponent(exchange))
        return finished
    }

    private static func attributes(of url: URL) throws -> stat? {
        var state = stat()
        if lstat(url.path, &state) == 0 { return state }
        if errno == ENOENT { return nil }
        throw posixError()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct CaptureRecord: Codable {
    var tool = "卷轴PDF · Living Scroll PDF \(Exporter.version)"
    var appName: String
    /// Private projects retain the title; public records keep an empty string for older readers.
    var windowTitle: String
    var startedAt: Date
    var endedAt: Date
    var framesStitched: Int
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

    static var outputFolder: URL { outputFolders[0] }

    /// Keep a capture's public filename stable across language changes and relaunches.
    /// Both historical names are still checked for interrupted exports and old libraries.
    static var outputFolders: [URL] {
        if let custom = ProcessInfo.processInfo.environment["JZ_OUT"] { return [URL(fileURLWithPath: custom, isDirectory: true)] }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let defaults = UserDefaults.standard, key = "desktopExportFolderName"
        let saved = defaults.string(forKey: key)
        let folders = desktopFolders(in: desktop, preferredName: L("卷轴PDF", "Living Scroll PDF"), savedName: saved)
        if saved != folders[0].lastPathComponent { defaults.set(folders[0].lastPathComponent, forKey: key) }
        return folders
    }

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
        let cleaned = supplied.components(separatedBy: unsafe).joined(separator: "-")
        // Leave room for the partial marker and extension even with multibyte filenames.
        var stem = ""
        for character in cleaned {
            if stem.utf8.count + String(character).utf8.count > 220 { break }
            stem.append(character)
        }
        if stem.isEmpty { stem = L("长截图", "Screenshot") }
        if record.isPartial && !stem.hasSuffix("-未完成") && !stem.lowercased().hasSuffix("-partial") {
            stem += L("-未完成", "-partial")
        }
        return stem
    }

    /// Encode all of the new products before replacing any public file.
    static func export(_ image: CGImage, record: CaptureRecord, folder: URL = outputFolder,
                       name: String? = nil, layers: [EditLayer] = [], layout: PDFLayout = pdfLayout) throws -> URL {
        let stem = fileStem(for: record, name: name)
        return try ExportPublication.write(in: folder, stem: stem) { png, pdf, json in
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
    }

    static func recoverPendingExport(in folder: URL) throws {
        try ExportPublication.recoverPending(in: folder)
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
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .cannotCreate(let url): return L("无法写入 \(url.path)", "Could not write \(url.path)")
            }
        }
    }
}

/// The directory inode is the cross-process lock. A prepared transaction contains only
/// the new public files. After a crash, the next writer finishes any remaining renames.
/// The JSON hashes are published last; readers can verify the pair they opened.
private enum ExportPublication {
    private static let extensions = ["png", "pdf", "json"]
    private static let owner = ".living-scroll-publication-v1"

    static func write(in folder: URL, stem: String,
                      render: (URL, URL, URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return try withOutputLock(in: folder) {
            let stage = stagingDirectory(in: folder)
            try recover(stage: stage, in: folder)
            return try write(stem: stem, in: folder, stage: stage, render: render)
        }
    }

    static func recoverPending(in folder: URL) throws {
        let stage = stagingDirectory(in: folder)
        guard try attributes(of: stage) != nil else { return }
        try withOutputLock(in: folder) { try recover(stage: stage, in: folder) }
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

    private static func write(stem: String, in folder: URL, stage: URL,
                              render: (URL, URL, URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer {
            // After marking the staged set ready, retain any unpublished products for retry.
            if !prepared { try? fm.removeItem(at: stage) }
        }
        try Data().write(to: stage.appendingPathComponent(owner))
        let png = stage.appendingPathComponent("output.png")
        let pdf = stage.appendingPathComponent("output.pdf")
        let json = stage.appendingPathComponent("output.json")
        try render(png, pdf, json)
        try validateDestinations(stem: stem, folder: folder)
        try Data().write(to: stage.appendingPathComponent(stem + ".ready"))
        prepared = true
        try publish(stage: stage, stem: stem, folder: folder)
        try fm.removeItem(at: stage)
        return folder.appendingPathComponent(stem + ".pdf")
    }

    private static func recover(stage: URL, in folder: URL) throws {
        guard let state = try attributes(of: stage) else { return }
        guard state.st_mode & S_IFMT == S_IFDIR else { throw Exporter.ExportError.cannotCreate(stage) }
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: stage.path)
        if !names.isEmpty {
            let pending = names.filter { $0.hasSuffix(".ready") }
            let known = Set(extensions.map { "output." + $0 } + [owner] + pending)
            // A reserved name occupied by unrelated files must survive an export attempt.
            guard names.contains(owner), pending.count <= 1, Set(names).isSubset(of: known) else {
                throw Exporter.ExportError.cannotCreate(stage)
            }
            if let marker = pending.first {
                let stem = String(marker.dropLast(".ready".count))
                guard !stem.isEmpty, stem != ".", stem != ".." else {
                    throw Exporter.ExportError.cannotCreate(stage)
                }
                try validateDestinations(stem: stem, folder: folder)
                try publish(stage: stage, stem: stem, folder: folder)
            }
        }
        // An interrupted encoder has no ready marker and has never touched public files.
        try fm.removeItem(at: stage)
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

    private static func publish(stage: URL, stem: String, folder: URL) throws {
        for ext in extensions {
            let source = stage.appendingPathComponent("output." + ext)
            let target = folder.appendingPathComponent(stem + "." + ext)
            if let state = try attributes(of: source) {
                guard state.st_mode & S_IFMT == S_IFREG else { throw Exporter.ExportError.cannotCreate(source) }
                guard Darwin.rename(source.path, target.path) == 0 else { throw posixError() }
            } else if try attributes(of: target) == nil {
                throw Exporter.ExportError.cannotCreate(target)
            }
        }
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

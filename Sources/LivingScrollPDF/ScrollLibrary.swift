import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Notification.Name {
    static let scrollLibraryDidChange = Notification.Name("LivingScrollPDF.scrollLibraryDidChange")
}

struct ScrollCategory: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

enum ScrollCategoryFilter: Equatable {
    case all, uncategorized, category(UUID)
}

struct ScrollEntry: Codable, Identifiable {
    let id: UUID
    var name: String
    let date: Date
    var categoryID: UUID?
    fileprivate let directoryID: UUID
    fileprivate var revision: UUID
    fileprivate var importedFrom: URL?
    fileprivate var importedHash: String?
    fileprivate var exportedStems: [String]?

    func matchingFilename(_ query: String) -> String? {
        if query.isEmpty { return name }
        return ([name] + (exportedStems ?? [])).first {
            ($0 + ".png").localizedStandardContains(query) || ($0 + ".pdf").localizedStandardContains(query)
        }
    }
}

/// The public PNG/PDF may be redacted. The editable original and its layers live together
/// in a private project directory, away from the files people send to others.
final class ScrollLibrary {
    static let shared = ScrollLibrary(outputFolder: preferredOutputFolder())

    let outputFolder: URL
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    init(outputFolder: URL) {
        self.outputFolder = outputFolder
        self.root = outputFolder.appendingPathComponent(".living-scroll-library", isDirectory: true)
    }

    static func preferredOutputFolder() -> URL {
        let current = Exporter.outputFolder
        if ProcessInfo.processInfo.environment["JZ_OUT"] != nil { return current }
        return existingDesktopFolder(preferred: current)
    }

    /// Use the first library created on this Desktop across subsequent language changes.
    static func existingDesktopFolder(preferred: URL) -> URL {
        let desktop = preferred.deletingLastPathComponent()
        let folders = ["Living Scroll PDF", "卷轴PDF"].map { desktop.appendingPathComponent($0, isDirectory: true) }
        return folders.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".living-scroll-library/index.json").path)
        } ?? preferred
    }

    private struct Index: Codable {
        var version = 1
        var categories: [ScrollCategory] = []
        var entries: [ScrollEntry] = []
    }

    /// Readers of the listings only read one atomically replaced file, including while
    /// another window is encoding a long PNG.
    private func readIndex() throws -> Index {
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Index()
        }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version == 1 else { throw LibraryError.version }
        return index
    }

    private func writeIndex(_ index: Index) throws {
        // Foundation's .atomic can request a replacement directory outside the writable
        // project on external volumes. An adjacent temporary file stays on the same mount.
        let temporary = root.appendingPathComponent(".index-" + UUID().uuidString + ".tmp")
        defer { try? fm.removeItem(at: temporary) }
        try JSONEncoder().encode(index).write(to: temporary)
        guard Darwin.rename(temporary.path, indexURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scrollLibraryDidChange, object: self)
        }
    }

    /// Multiple editor windows (and separate instances using the same output directory)
    /// must merge changes against the current index. The lock inode survives index swaps.
    private func withProjectLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        while flock(descriptor, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    func categories() throws -> [ScrollCategory] {
        try readIndex().categories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entries(matching query: String = "", category: ScrollCategoryFilter = .all) throws -> [ScrollEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try readIndex().entries.filter { entry in
            switch category {
            case .category(let id) where entry.categoryID != id: return false
            case .uncategorized where entry.categoryID != nil: return false
            default: break
            }
            return entry.matchingFilename(search) != nil
        }.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    @discardableResult
    func addCategory(_ name: String) throws -> ScrollCategory {
        try withProjectLock(exclusive: true) {
            var index = try readIndex()
            let category = ScrollCategory(id: UUID(), name: try categoryName(name, in: index))
            index.categories.append(category)
            try writeIndex(index)
            return category
        }
    }

    func renameCategory(_ id: UUID, to name: String) throws {
        try withProjectLock(exclusive: true) {
            var index = try readIndex()
            guard let i = index.categories.firstIndex(where: { $0.id == id }) else { throw LibraryError.categoryGone }
            let clean = try categoryName(name, in: index, excluding: id)
            index.categories[i].name = clean
            try writeIndex(index)
        }
    }

    func deleteCategory(_ id: UUID) throws {
        try withProjectLock(exclusive: true) {
            var index = try readIndex()
            guard let i = index.categories.firstIndex(where: { $0.id == id }) else { throw LibraryError.categoryGone }
            index.categories.remove(at: i)
            for j in index.entries.indices where index.entries[j].categoryID == id {
                index.entries[j].categoryID = nil
            }
            try writeIndex(index)
        }
    }

    private func categoryName(_ name: String, in index: Index, excluding id: UUID? = nil) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.emptyName }
        guard !index.categories.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame })
        else { throw LibraryError.duplicateCategory }
        return clean
    }

    private func project(_ directoryID: UUID) -> URL {
        root.appendingPathComponent("projects", isDirectory: true).appendingPathComponent(directoryID.uuidString, isDirectory: true)
    }

    private func sidecar(_ entry: ScrollEntry) -> URL {
        project(entry.directoryID).appendingPathComponent(entry.revision.uuidString + ".edit.json")
    }

    func originalURL(for id: UUID) throws -> URL {
        guard let entry = try readIndex().entries.first(where: { $0.id == id }) else { throw LibraryError.projectGone }
        return project(entry.directoryID).appendingPathComponent("original.png")
    }

    /// Save the stem actually published by Exporter, including any collision suffix.
    /// Former export names remain searchable after the editable project is renamed.
    func recordExport(_ pdf: URL, for id: UUID) throws {
        try withProjectLock(exclusive: true) {
            var index = try readIndex()
            guard let i = index.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.projectGone }
            let stem = pdf.deletingPathExtension().lastPathComponent
            var names = index.entries[i].exportedStems ?? []
            guard !names.contains(stem) else { return }
            names.append(stem)
            index.entries[i].exportedStems = names
            try writeIndex(index)
        }
    }

    @discardableResult
    func save(_ document: EditDocument, original: CGImage, categoryID: UUID?) throws -> EditDocument {
        try withProjectLock(exclusive: true) {
            try save(document, original: original, categoryID: categoryID, index: readIndex())
        }
    }

    /// New sidecars are immutable until the index points to them. If writing fails or the
    /// process stops before that switch, the previous name, category and layers still agree.
    @discardableResult
    private func save(_ document: EditDocument, original: CGImage, categoryID: UUID?, index previous: Index,
                      importedFrom: URL? = nil, importedHash: String? = nil) throws -> EditDocument {
        var document = document
        document.name = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !document.name.isEmpty else { throw LibraryError.emptyName }
        guard document.version == 1 else { throw LibraryError.version }
        guard document.record.pixelWidth == original.width, document.record.pixelHeight == original.height
        else { throw LibraryError.dimensions }
        var index = previous
        if let id = categoryID, !index.categories.contains(where: { $0.id == id }) {
            throw LibraryError.categoryGone
        }
        var position = index.entries.firstIndex { $0.id == document.id }
        var copySource: URL?
        if let i = position, document.revision != index.entries[i].revision {
            // A second running copy can have a different edit of the same original.
            // Keep both drafts and return the identity that subsequent saves should use.
            copySource = project(index.entries[i].directoryID).appendingPathComponent("original.png")
            document.id = UUID()
            document.name += L("（编辑副本）", " (edited copy)")
            position = nil
        }
        let old = position.map { index.entries[$0] }
        // An interrupted first save may have left a directory unpublished. Leave it alone.
        let directoryID = old?.directoryID ?? (fm.fileExists(atPath: project(document.id).path) ? UUID() : document.id)
        let entry = ScrollEntry(id: document.id, name: document.name, date: document.record.endedAt, categoryID: categoryID,
                                directoryID: directoryID, revision: UUID(), importedFrom: old?.importedFrom ?? importedFrom,
                                importedHash: old?.importedHash ?? importedHash, exportedStems: old?.exportedStems)
        document.revision = entry.revision
        let folder = project(directoryID)
        let source = folder.appendingPathComponent("original.png")
        let data = try JSONEncoder().encode(document)
        let next = sidecar(entry)
        if old == nil {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        do {
            if old == nil {
                if let copySource {
                    try fm.copyItem(at: copySource, to: source)
                } else if let importedFrom {
                    // Keep the exact bytes in the legacy capture's PNG hash.
                    try fm.copyItem(at: importedFrom, to: source)
                    guard try Exporter.sha256(of: source) == importedHash else { throw LibraryError.recordMismatch }
                } else {
                    try Exporter.writePNG(original, to: source)
                }
            } else if !fm.fileExists(atPath: source.path) {
                throw LibraryError.originalGone
            }
            try data.write(to: next)
            if let position { index.entries[position] = entry } else { index.entries.append(entry) }
            try writeIndex(index)
        } catch {
            if old == nil { try? fm.removeItem(at: folder) } else { try? fm.removeItem(at: next) }
            throw error
        }
        if let old { try? fm.removeItem(at: sidecar(old)) }
        return document
    }

    func load(_ id: UUID) throws -> (document: EditDocument, original: CGImage, categoryID: UUID?) {
        try withProjectLock(exclusive: false) {
            guard let entry = try readIndex().entries.first(where: { $0.id == id }) else { throw LibraryError.projectGone }
            var document = try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: sidecar(entry)))
            guard document.version == 1 else { throw LibraryError.version }
            guard document.id == entry.id else { throw LibraryError.recordMismatch }
            if let revision = document.revision, revision != entry.revision { throw LibraryError.recordMismatch }
            document.revision = entry.revision
            let original = try readPNG(project(entry.directoryID).appendingPathComponent("original.png"))
            guard document.record.pixelWidth == original.width, document.record.pixelHeight == original.height
            else { throw LibraryError.dimensions }
            return (document, original, entry.categoryID)
        }
    }

    private func readPNG(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LibraryError.invalidImage }
        return image
    }

    /// Opening the same legacy PNG resumes its layers. A current export includes a project
    /// ID in its record, so reopening the public image can return to the local original.
    @discardableResult
    func importPNG(at url: URL, categoryID: UUID? = nil) throws -> UUID {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let known = try readIndex()
        if let entry = known.entries.first(where: {
            project($0.directoryID).appendingPathComponent("original.png").resolvingSymlinksInPath() == file
        }) { return entry.id }

        let digest = try Exporter.sha256(of: file)
        let image = try readPNG(file)
        let name = file.deletingPathExtension().lastPathComponent
        let recordURL = file.deletingPathExtension().appendingPathExtension("json")
        let record: CaptureRecord
        if fm.fileExists(atPath: recordURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: recordURL)
            record = try decoder.decode(CaptureRecord.self, from: data)
            guard record.pixelWidth == image.width, record.pixelHeight == image.height, record.pointScale.isFinite,
                  record.pointScale >= 1, record.pngSHA256.isEmpty || record.pngSHA256 == digest else {
                throw LibraryError.recordMismatch
            }
            if let id = record.editingProjectID, known.entries.contains(where: { $0.id == id }) { return id }
        } else {
            let imported = Date()
            record = CaptureRecord(appName: L("导入的 PNG", "Imported PNG"), windowTitle: name,
                                   startedAt: imported, endedAt: imported, framesStitched: 0, droppedFrames: 0,
                                   pixelWidth: image.width, pixelHeight: image.height, pointScale: 1)
        }
        return try withProjectLock(exclusive: true) {
            let index = try readIndex()
            if let prior = index.entries.first(where: { $0.importedFrom == file && $0.importedHash == digest }) {
                return prior.id
            }
            let document = EditDocument(name: name, record: record)
            try save(document, original: image, categoryID: categoryID, index: index, importedFrom: file, importedHash: digest)
            return document.id
        }
    }

    private enum LibraryError: LocalizedError {
        case version, emptyName, duplicateCategory, categoryGone, projectGone, originalGone, dimensions, invalidImage, recordMismatch
        var errorDescription: String? {
            switch self {
            case .version: return L("请用较新版本的卷轴PDF打开这个文件。", "A newer version of Living Scroll PDF is needed to open this file.")
            case .emptyName: return L("请输入名称。", "Enter a name.")
            case .duplicateCategory: return L("已有同名分类。", "A category with this name already exists.")
            case .categoryGone: return L("这个分类已被删除，请重新选择。", "This category was deleted. Choose another category.")
            case .projectGone: return L("图库条目已变更，请重新打开图库。", "This library entry changed. Reopen the library.")
            case .originalGone: return L("读取原图失败，请检查截图库的项目文件夹。", "The original PNG could not be read. Check the library’s project folder.")
            case .dimensions: return L("原图尺寸与编辑记录不一致。", "The original image dimensions do not match the edit record.")
            case .invalidImage: return L("无法读取这张 PNG。", "This PNG could not be read.")
            case .recordMismatch: return L("截图与随附记录不匹配。", "The screenshot does not match its accompanying record.")
            }
        }
    }
}

import CoreGraphics
import CryptoKit
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
    fileprivate(set) var id: UUID
    var name: String
    fileprivate(set) var date: Date
    var categoryID: UUID?
    fileprivate let directoryID: UUID
    /// Migrated v0.3 libraries keep their original project folders inside this private collection.
    fileprivate var collection: UUID?
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
    static let shared: ScrollLibrary = {
        let folders = Exporter.outputFolders
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ScrollLibrary(outputFolder: folders[0], root: support.appendingPathComponent("LivingScrollPDF/Library", isDirectory: true),
                             legacyOutputFolders: folders)
    }()

    let outputFolder: URL
    private let root: URL
    let legacyOutputFolders: [URL]
    private let preparationLock = NSLock()
    private var storageReady = false
    private var migrationComplete = false
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    init(outputFolder: URL, root: URL, legacyOutputFolders: [URL]? = nil) {
        self.outputFolder = outputFolder
        self.root = root
        var paths = Set<String>()
        self.legacyOutputFolders = (legacyOutputFolders ?? [outputFolder]).filter { paths.insert($0.standardizedFileURL.path).inserted }
    }

    private struct Index: Codable {
        var version = 1
        var categories: [ScrollCategory] = []
        var entries: [ScrollEntry] = []
    }

    private struct VersionHeader: Decodable { let version: Int }

    /// Missing and malformed indexes can be rebuilt. A newer format or an I/O error
    /// must not be mistaken for corrupt data and overwritten.
    private func decodedIndex(at url: URL) throws -> Index? {
        if let kind = try type(of: url), kind != .typeRegular { throw LibraryError.invalidLocation }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        if let version = try? decoder.decode(VersionHeader.self, from: data).version, version > 1 {
            throw LibraryError.version
        }
        guard let index = try? decoder.decode(Index.self, from: data), index.version == 1,
              Set(index.entries.map(\.id)).count == index.entries.count,
              Set(index.entries.map { ($0.collection?.uuidString ?? "") + $0.directoryID.uuidString }).count == index.entries.count,
              Set(index.categories.map(\.id)).count == index.categories.count else { return nil }
        return index
    }

    /// Healthy listings remain lock-free while another window encodes a capture.
    private func readIndex() throws -> Index {
        try prepare(reportMigrationError: false)
        if let index = try decodedIndex(at: indexURL) { return index }
        return try withFileLock(in: root) { try indexLocked() }
    }

    private func replace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString + ".tmp")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary)
        try publishPrivateFile(temporary, to: url)
    }

    private func publishPrivateFile(_ staged: URL, to file: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        try renameItem(staged, to: file)
    }

    private func writeIndex(_ index: Index) throws {
        try replace(JSONEncoder().encode(index), at: indexURL)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .scrollLibraryDidChange, object: self)
        }
    }

    private func renameItem(_ source: URL, to target: URL) throws {
        guard Darwin.rename(source.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func withProjectLock<T>(_ body: () throws -> T) throws -> T {
        try prepare(reportMigrationError: false)
        return try withFileLock(in: root, body)
    }

    private func withFileLock<T>(in folder: URL, _ body: () throws -> T) throws -> T {
        guard try type(of: folder) == .typeDirectory else { throw LibraryError.invalidLocation }
        let descriptor = Darwin.open(folder.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    private func type(of url: URL) throws -> FileAttributeType? {
        do {
            return try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    private func privateDirectory(_ url: URL) throws {
        if try type(of: url) == nil {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard try type(of: url) == .typeDirectory else { throw LibraryError.invalidLocation }
    }

    private var collections: URL { root.appendingPathComponent("imports", isDirectory: true) }

    private func storage(_ collection: UUID?) -> URL {
        guard let collection else { return root }
        return collections.appendingPathComponent(collection.uuidString, isDirectory: true)
    }

    private func children(_ url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The old .lock coordinates with v0.3 processes. A same-volume rename moves all
    /// private files together, including unindexed projects. Across volumes we verify the
    /// private copy before unlinking the source. The source inode identifies a retry.
    private func migrate(_ legacy: URL) throws {
        guard let kind = try type(of: legacy) else { return }
        guard kind == .typeDirectory,
              legacy.resolvingSymlinksInPath().standardizedFileURL != root.resolvingSymlinksInPath().standardizedFileURL else {
            throw LibraryError.invalidLocation
        }
        try withFileLock(in: legacy) {
            // Leave a future version intact for the app that wrote it. An unreadable
            // Desktop must not hold up captures going into the independent private store.
            _ = try decodedIndex(at: legacy.appendingPathComponent("index.json"))
            let attributes = try fm.attributesOfItem(atPath: legacy.path)
            let identity = "\(legacy.standardizedFileURL.path):\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(attributes[.creationDate] ?? "")"
            var group = stableID(identity)
            try privateDirectory(collections)
            var destination = storage(group)
            if try type(of: destination) != nil {
                if try includesFiles(at: legacy, in: destination) {
                    try fm.removeItem(at: legacy)
                    return
                }
                // An older running app has added different files since copying. Keep both.
                group = UUID()
                destination = storage(group)
            }
            try validateTree(legacy)
            do {
                try renameItem(legacy, to: destination)
            } catch let error as POSIXError where error.code == .EXDEV {
                let partial = collections.appendingPathComponent(".copy-" + group.uuidString)
                if try type(of: partial) != nil { try fm.removeItem(at: partial) }
                defer { try? fm.removeItem(at: partial) }
                try fm.copyItem(at: legacy, to: partial)
                guard try includesFiles(at: legacy, in: partial) else { throw LibraryError.recordMismatch }
                try renameItem(partial, to: destination)
                try fm.removeItem(at: legacy)
            }
        }
    }

    private func stableID(_ input: String) -> UUID {
        SHA256.hash(data: Data(input.utf8)).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    private func validateTree(_ directory: URL) throws {
        for item in try children(directory) {
            switch try type(of: item) {
            case .typeDirectory: try validateTree(item)
            case .typeRegular: break
            default: throw LibraryError.invalidLocation
            }
        }
    }

    /// A partially removed legacy tree is safe to finish removing only if every
    /// remaining file is already present, byte for byte, in the private destination.
    private func includesFiles(at source: URL, in destination: URL) throws -> Bool {
        guard let kind = try type(of: source), try type(of: destination) == kind else { return false }
        switch kind {
        case .typeRegular: return try Exporter.sha256(of: source) == Exporter.sha256(of: destination)
        case .typeDirectory:
            for item in try children(source) {
                if try !includesFiles(at: item, in: destination.appendingPathComponent(item.lastPathComponent)) { return false }
            }
            return true
        default: throw LibraryError.invalidLocation
        }
    }

    private func collectionIDs() throws -> [UUID] {
        guard let kind = try type(of: collections) else { return [] }
        guard kind == .typeDirectory else { throw LibraryError.invalidLocation }
        return try children(collections).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            guard try type(of: url) == .typeDirectory else { throw LibraryError.invalidLocation }
            return id
        }
    }

    private func importedMarker(_ id: UUID) -> URL {
        root.appendingPathComponent(".imported-" + id.uuidString)
    }

    /// Startup reports pending migrations; ordinary capture/storage operations only
    /// depend on the health of their own private library. A later prepare() retries.
    func prepare() throws {
        try prepare(reportMigrationError: true)
    }

    private func prepare(reportMigrationError: Bool) throws {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        if storageReady && (!reportMigrationError || migrationComplete) { return }
        try privateDirectory(root)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        var migrationError: Error?
        try withFileLock(in: root) {
            var index = try indexLocked()
            try finishDeletions(in: &index)
            // A crash after the first PNG/sidecar reached disk but before its index
            // commit must still leave a visible draft, even when the old index is valid.
            let missing = try scan(collection: nil, excluding: index.entries)
            if !missing.isEmpty {
                try mergeEntries(missing, into: &index)
                try writeIndex(index)
            }
            for folder in legacyOutputFolders {
                do { try migrate(folder.appendingPathComponent(".living-scroll-library", isDirectory: true)) }
                catch { migrationError = migrationError ?? error }
            }
            do {
                for id in try collectionIDs() {
                    do { try finishMigration(id, into: &index) }
                    catch { migrationError = migrationError ?? error }
                }
            } catch { migrationError = migrationError ?? error }
            // Earlier versions could import an original with its public file mode.
            for entry in index.entries {
                do { try restrictExistingProjectFiles(entry) }
                catch LibraryError.invalidLocation { continue } // Only visit verified private directories.
                catch { migrationError = migrationError ?? error }
            }
        }
        storageReady = true
        migrationComplete = migrationError == nil
        if reportMigrationError, let migrationError { throw LibraryError.migrationPending(migrationError) }
    }

    private func restrictExistingProjectFiles(_ entry: ScrollEntry) throws {
        try checkProjectFolder(entry)
        let directory = project(entry)
        for url in try children(directory) where url.lastPathComponent == "original.png" || url.lastPathComponent.hasSuffix(".edit.json") {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.posixPermissions] as? Int != 0o600 else { continue }
            if (attributes[.referenceCount] as? Int ?? 1) > 1 {
                // A migrated hard link must not change the mode of someone's public copy.
                let copy = directory.appendingPathComponent(".mode-" + UUID().uuidString)
                defer { try? fm.removeItem(at: copy) }
                try fm.copyItem(at: url, to: copy)
                try publishPrivateFile(copy, to: url)
            } else {
                guard fchmodat(AT_FDCWD, url.path, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func finishMigration(_ id: UUID, into index: inout Index) throws {
        let marker = importedMarker(id), previousIndex = storage(id).appendingPathComponent("index.json")
        if try type(of: marker) == nil {
            let legacyIndex = try decodedIndex(at: previousIndex)
            if legacyIndex == nil { try quarantine(previousIndex) }
            var merged = index
            let duplicates = try merge(legacyIndex ?? Index(), collection: id, into: &merged)
            try writeIndex(merged)
            index = merged
            for folder in duplicates { try fm.removeItem(at: folder) }
            try replace(Data(), at: marker)
        }
        if try type(of: previousIndex) != nil { try fm.removeItem(at: previousIndex) }
    }

    private func merge(_ incoming: Index, collection: UUID, into index: inout Index) throws -> [URL] {
        var categories: [UUID: UUID] = [:]
        for category in incoming.categories {
            if let same = index.categories.first(where: { $0.name.localizedCaseInsensitiveCompare(category.name) == .orderedSame }) {
                categories[category.id] = same.id
            } else {
                let id = index.categories.contains { $0.id == category.id } ? stableID(collection.uuidString + category.id.uuidString) : category.id
                index.categories.append(ScrollCategory(id: id, name: category.name))
                categories[category.id] = id
            }
        }
        var entries = incoming.entries.map { old -> ScrollEntry in
            var entry = old
            entry.collection = collection
            entry.categoryID = old.categoryID.flatMap { categories[$0] }
            return entry
        }
        entries += try scan(collection: collection, excluding: entries)
        return try mergeEntries(entries, into: &index, combiningIdenticalProjects: true)
    }

    @discardableResult
    private func mergeEntries(_ entries: [ScrollEntry], into index: inout Index, combiningIdenticalProjects: Bool = false) throws -> [URL] {
        var duplicates: [URL] = []
        for var entry in entries {
            if index.entries.contains(where: { $0.collection == entry.collection && $0.directoryID == entry.directoryID }) { continue }
            let folder = project(entry)
            guard try type(of: folder) == .typeDirectory else { continue }
            if let i = index.entries.firstIndex(where: { $0.id == entry.id }) {
                let existing = index.entries[i]
                if combiningIdenticalProjects, existing.revision == entry.revision, existing.name == entry.name, existing.categoryID == entry.categoryID,
                   existing.importedFrom == entry.importedFrom, existing.importedHash == entry.importedHash,
                   try includesFiles(at: folder, in: project(existing)) {
                    let names = (existing.exportedStems ?? []) + (entry.exportedStems ?? [])
                    index.entries[i].exportedStems = Array(Set(names)).sorted()
                    duplicates.append(folder)
                    continue
                }
                // Two localized legacy folders can contain divergent copies of one project.
                // Assign the second version a deterministic identity so a retry can finish.
                let id = stableID((entry.collection?.uuidString ?? "private") + entry.directoryID.uuidString)
                for file in try children(folder) where file.lastPathComponent.hasSuffix(".edit.json") {
                    guard try type(of: file) == .typeRegular else { continue }
                    let data = try Data(contentsOf: file)
                    guard var doc = try? JSONDecoder().decode(EditDocument.self, from: data),
                          doc.version == 1, doc.id == entry.id else { continue }
                    doc.id = id
                    try replace(JSONEncoder().encode(doc), at: file)
                }
                entry.id = id
            }
            index.entries.append(entry)
        }
        return duplicates
    }

    private func quarantine(_ url: URL, keepingCurrent: Bool = false) throws {
        guard try type(of: url) != nil else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent().appendingPathComponent("index.corrupt-\(stamp)-\(UUID().uuidString).json")
        if keepingCurrent { try fm.copyItem(at: url, to: backup) }
        else { try fm.moveItem(at: url, to: backup) }
    }

    /// Caller holds the private library's exclusive lock. Recovery scans metadata and
    /// never decodes a whole long PNG into memory merely to list it.
    private func indexLocked() throws -> Index {
        if let index = try decodedIndex(at: indexURL) { return index }
        var index = Index()
        try mergeEntries(scan(collection: nil), into: &index)
        for id in try collectionIDs() where try type(of: importedMarker(id)) == .typeRegular {
            try mergeEntries(scan(collection: id), into: &index)
        }
        try quarantine(indexURL, keepingCurrent: true)
        try writeIndex(index)
        return index
    }

    private func scan(collection: UUID?, excluding entries: [ScrollEntry] = []) throws -> [ScrollEntry] {
        let projects = storage(collection).appendingPathComponent("projects", isDirectory: true)
        guard let kind = try type(of: projects) else { return [] }
        guard kind == .typeDirectory else { throw LibraryError.invalidLocation }
        let known = Set(entries.filter { $0.collection == collection }.map(\.directoryID))
        var recovered: [ScrollEntry] = []
        for folder in try children(projects) {
            let original = folder.appendingPathComponent("original.png")
            guard let directoryID = UUID(uuidString: folder.lastPathComponent), !known.contains(directoryID),
                  try type(of: folder) == .typeDirectory else { continue }
            let staged = folder.appendingPathComponent(".original.pending")
            if collection == nil, try type(of: original) == nil, try type(of: staged) == .typeRegular {
                // A process can stop either inside the encoder or just before rename.
                if try completePNG(at: staged) { try publishPrivateFile(staged, to: original) }
                else { try fm.removeItem(at: staged) }
            }
            guard try type(of: original) == .typeRegular, try completePNG(at: original),
                  let source = CGImageSourceCreateWithURL(original as CFURL, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            guard let doc = try newestDocument(in: folder, width: width, height: height), let revision = doc.revision else { continue }
            recovered.append(ScrollEntry(id: doc.id, name: doc.name, date: doc.record.endedAt, categoryID: nil,
                                         directoryID: directoryID, collection: collection, revision: revision))
        }
        return recovered
    }

    /// A bad revision must not hide the other complete sidecars in this same directory.
    /// Restrict a targeted repair to its original identity and honor newer formats.
    private func newestDocument(in folder: URL, width: Int, height: Int, id: UUID? = nil) throws -> EditDocument? {
        let sidecars = try children(folder).filter { $0.lastPathComponent.hasSuffix(".edit.json") }
        let latest = try sidecars.compactMap { url -> (Date, URL)? in
            guard try type(of: url) == .typeRegular else { return nil }
            return (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast, url)
        }.sorted { $0.0 == $1.0 ? $0.1.lastPathComponent > $1.1.lastPathComponent : $0.0 > $1.0 }
        for (_, url) in latest {
            guard let revision = UUID(uuidString: String(url.lastPathComponent.dropLast(".edit.json".count))) else { continue }
            if let document = try document(at: url, revision: revision, width: width, height: height, id: id) { return document }
        }
        return nil
    }

    private func document(at url: URL, revision: UUID, width: Int, height: Int, id: UUID?) throws -> EditDocument? {
        guard let kind = try type(of: url) else { return nil }
        guard kind == .typeRegular else { throw LibraryError.invalidLocation }
        let data = try Data(contentsOf: url), decoder = JSONDecoder()
        if id != nil, let version = try? decoder.decode(VersionHeader.self, from: data).version, version > 1 {
            throw LibraryError.version
        }
        guard var doc = try? decoder.decode(EditDocument.self, from: data), doc.version == 1,
              id == nil || doc.id == id, doc.record.pixelWidth == width, doc.record.pixelHeight == height,
              doc.revision == nil || doc.revision == revision else { return nil }
        doc.revision = revision
        return doc
    }

    private func finishDeletions(in index: inout Index) throws {
        let prefix = ".deleting-"
        for tomb in try children(root) where tomb.lastPathComponent.hasPrefix(prefix) {
            guard let id = UUID(uuidString: String(tomb.lastPathComponent.dropFirst(prefix.count))) else { continue }
            if index.entries.contains(where: { $0.id == id }) {
                index.entries.removeAll { $0.id == id }
                try writeIndex(index)
            }
            try fm.removeItem(at: tomb)
        }
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
        try withProjectLock {
            var index = try indexLocked()
            let category = ScrollCategory(id: UUID(), name: try categoryName(name, in: index))
            index.categories.append(category)
            try writeIndex(index)
            return category
        }
    }

    func renameCategory(_ id: UUID, to name: String) throws {
        try withProjectLock {
            var index = try indexLocked()
            guard let i = index.categories.firstIndex(where: { $0.id == id }) else { throw LibraryError.categoryGone }
            let clean = try categoryName(name, in: index, excluding: id)
            index.categories[i].name = clean
            try writeIndex(index)
        }
    }

    func deleteCategory(_ id: UUID) throws {
        try withProjectLock {
            var index = try indexLocked()
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

    private func project(_ directoryID: UUID, collection: UUID? = nil) -> URL {
        storage(collection).appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(directoryID.uuidString, isDirectory: true)
    }

    private func project(_ entry: ScrollEntry) -> URL {
        project(entry.directoryID, collection: entry.collection)
    }

    private func checkProjectFolder(_ entry: ScrollEntry, creating: Bool = false) throws {
        guard try type(of: root) == .typeDirectory else { throw LibraryError.invalidLocation }
        if let group = entry.collection {
            guard try type(of: collections) == .typeDirectory, try type(of: storage(group)) == .typeDirectory else {
                throw LibraryError.invalidLocation
            }
        }
        let folder = project(entry), parent = folder.deletingLastPathComponent()
        if creating {
            try privateDirectory(parent)
            try privateDirectory(folder)
        } else {
            guard try type(of: parent) == .typeDirectory, try type(of: folder) == .typeDirectory else {
                throw LibraryError.invalidLocation
            }
        }
    }

    private func sidecar(_ entry: ScrollEntry) -> URL {
        project(entry).appendingPathComponent(entry.revision.uuidString + ".edit.json")
    }

    func originalURL(for id: UUID) throws -> URL {
        guard let entry = try readIndex().entries.first(where: { $0.id == id }) else { throw LibraryError.projectGone }
        try checkProjectFolder(entry)
        let url = project(entry).appendingPathComponent("original.png")
        guard try type(of: url) == .typeRegular else { throw LibraryError.originalGone }
        return url
    }

    /// Rename out of the scannable project tree first. After a crash, preparation
    /// finishes this confirmed deletion before another editor can save the old revision.
    func delete(_ id: UUID) throws {
        try withProjectLock {
            var index = try indexLocked()
            guard let i = index.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.projectGone }
            let entry = index.entries.remove(at: i)
            try checkProjectFolder(entry)
            let folder = project(entry), tomb = root.appendingPathComponent(".deleting-" + id.uuidString)
            try renameItem(folder, to: tomb)
            do {
                try writeIndex(index)
            } catch {
                try renameItem(tomb, to: folder)
                throw error
            }
            try fm.removeItem(at: tomb)
        }
    }

    /// Save the stem actually published by Exporter.
    /// Former export names remain searchable after the editable project is renamed.
    func recordExport(_ pdf: URL, for id: UUID) throws {
        try withProjectLock {
            var index = try indexLocked()
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
        try withProjectLock {
            try save(document, original: original, categoryID: categoryID, index: indexLocked())
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
        if position == nil, document.revision == nil, try type(of: project(document.id)) == .typeDirectory {
            // The first index write may have failed after the original was completed.
            // Reuse that durable capture on retry instead of making an extra original.
            try mergeEntries(scan(collection: nil, excluding: index.entries), into: &index)
            position = index.entries.firstIndex { $0.id == document.id }
            document.revision = position.map { index.entries[$0].revision }
        }
        if position == nil, document.revision != nil { throw LibraryError.projectGone }
        var copySource: URL?
        if let i = position, document.revision != index.entries[i].revision {
            // A second running copy can have a different edit of the same original.
            // Keep both drafts and return the identity that subsequent saves should use.
            try checkProjectFolder(index.entries[i])
            copySource = project(index.entries[i]).appendingPathComponent("original.png")
            document.id = UUID()
            document.name += L("（编辑副本）", " (edited copy)")
            position = nil
        }
        let old = position.map { index.entries[$0] }
        // An interrupted first save may have left a directory unpublished. Leave it alone.
        let directoryID = old?.directoryID ?? (fm.fileExists(atPath: project(document.id).path) ? UUID() : document.id)
        let entry = ScrollEntry(id: document.id, name: document.name, date: document.record.endedAt, categoryID: categoryID,
                                directoryID: directoryID, collection: old?.collection, revision: UUID(), importedFrom: old?.importedFrom ?? importedFrom,
                                importedHash: old?.importedHash ?? importedHash, exportedStems: old?.exportedStems)
        document.revision = entry.revision
        let folder = project(entry)
        let source = folder.appendingPathComponent("original.png")
        let data = try JSONEncoder().encode(document)
        let next = sidecar(entry)
        try checkProjectFolder(entry, creating: old == nil)
        var filesReady = false
        do {
            try replace(data, at: next)
            if old == nil {
                let staged = folder.appendingPathComponent(".original.pending")
                if let copySource {
                    guard try type(of: copySource) == .typeRegular else { throw LibraryError.originalGone }
                    try fm.copyItem(at: copySource, to: staged)
                } else if let importedFrom {
                    // Keep the exact bytes in the legacy capture's PNG hash.
                    try fm.copyItem(at: importedFrom, to: staged)
                    guard try Exporter.sha256(of: staged) == importedHash else { throw LibraryError.recordMismatch }
                } else {
                    try Exporter.writePNG(original, to: staged)
                }
                try publishPrivateFile(staged, to: source)
            } else if try type(of: source) != .typeRegular {
                throw LibraryError.originalGone
            }
            filesReady = true
            if let position { index.entries[position] = entry } else { index.entries.append(entry) }
            try writeIndex(index)
        } catch {
            if old != nil { try? fm.removeItem(at: next) }
            else if !filesReady { try? fm.removeItem(at: folder) }
            throw error
        }
        if let old { try? fm.removeItem(at: sidecar(old)) }
        return document
    }

    func load(_ id: UUID) throws -> (document: EditDocument, original: CGImage, categoryID: UUID?) {
        try withProjectLock {
            var index = try indexLocked()
            guard let i = index.entries.firstIndex(where: { $0.id == id }) else { throw LibraryError.projectGone }
            let entry = index.entries[i]
            try checkProjectFolder(entry)
            let file = project(entry).appendingPathComponent("original.png")
            guard try type(of: file) == .typeRegular else { throw LibraryError.originalGone }
            let image = try readPNG(file)
            let indexed = try document(at: sidecar(entry), revision: entry.revision, width: image.width, height: image.height, id: id)
            guard let doc = try indexed ?? newestDocument(in: project(entry), width: image.width, height: image.height, id: id),
                  let revision = doc.revision else { throw LibraryError.recordMismatch }
            if entry.revision != revision || entry.name != doc.name || entry.date != doc.record.endedAt {
                // This index decodes, but no longer describes the actual saved revision.
                // Keep a byte-exact backup and all unrelated library metadata.
                index.entries[i].revision = revision
                index.entries[i].name = doc.name
                index.entries[i].date = doc.record.endedAt
                try quarantine(indexURL, keepingCurrent: true)
                try writeIndex(index)
            }
            return (doc, image, entry.categoryID)
        }
    }

    private func readPNG(_ url: URL) throws -> CGImage {
        guard try completePNG(at: url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LibraryError.invalidImage }
        return image
    }

    /// ImageIO reports .statusComplete for truncated, non-incremental PNG sources
    /// that have a readable header. Require a complete IEND chunk as well. An imported
    /// PNG may have trailing bytes; follow its chunk lengths without reading pixel data.
    private func completePNG(at url: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let end = Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
        guard size >= 20 else { return false }
        try file.seek(toOffset: size - 12)
        if try file.read(upToCount: 12) == end { return true }
        var offset: UInt64 = 8
        while size - offset >= 12 {
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 8), header.count == 8 else { return false }
            let length = UInt64(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard length <= size - offset - 12 else { return false }
            if header == end.prefix(8) { return try file.read(upToCount: 4) == end.suffix(4) }
            offset += length + 12
        }
        return false
    }

    /// Opening the same legacy PNG resumes its layers. A current export includes a project
    /// ID in its record, so reopening the public image can return to the local original.
    @discardableResult
    func importPNG(at url: URL, categoryID: UUID? = nil) throws -> UUID {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let known = try readIndex()
        if let entry = known.entries.first(where: {
            project($0).appendingPathComponent("original.png").resolvingSymlinksInPath() == file
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
        return try withProjectLock {
            let index = try indexLocked()
            if let prior = index.entries.first(where: { $0.importedFrom == file && $0.importedHash == digest }) {
                return prior.id
            }
            let document = EditDocument(name: name, record: record)
            try save(document, original: image, categoryID: categoryID, index: index, importedFrom: file, importedHash: digest)
            return document.id
        }
    }

    private enum LibraryError: LocalizedError {
        case version, emptyName, duplicateCategory, categoryGone, projectGone, originalGone, dimensions, invalidImage, recordMismatch, invalidLocation
        case migrationPending(Error)
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
            case .invalidLocation: return L("图库路径已更改，请检查项目文件夹。", "The library path has changed. Check its project folder.")
            case .migrationPending(let error): return L("旧图库尚待迁移。", "Migration of an older library is still pending. ") + error.localizedDescription
            }
        }
    }
}

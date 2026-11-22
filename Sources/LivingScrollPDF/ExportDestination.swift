import Foundation

/// The destination and its recovery policy for a single export. A newly selected
/// folder must already exist. The desktop default and JZ_OUT may be created.
struct ExportDestination {
    let defaultFolder: URL
    let legacyFolders: [URL]
    let customFolder: URL?
    let pendingExports: PendingCustomExports?

    init(defaultFolder: URL, legacyFolders: [URL] = [], customFolder: URL? = nil, pendingExports: PendingCustomExports? = nil) {
        self.defaultFolder = defaultFolder
        var paths = Set<String>()
        self.legacyFolders = legacyFolders.filter { paths.insert($0.standardizedFileURL.path).inserted }
        self.customFolder = customFolder
        self.pendingExports = pendingExports
    }

    private static let customKey = "customExportFolderPath"
    private static let desktopNameKey = "desktopExportFolderName"

    static func savedDesktopName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: desktopNameKey)
    }

    static func setCustomFolder(_ folder: URL?, defaults: UserDefaults = .standard) {
        if let folder { defaults.set(folder.path, forKey: customKey) }
        else { defaults.removeObject(forKey: customKey) }
    }

    static func current(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        desktop: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)) -> Self {
        if let path = environment["JZ_OUT"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            return Self(defaultFolder: folder, legacyFolders: [folder])
        }
        let saved = savedDesktopName(in: defaults)
        let old = Exporter.desktopFolders(in: desktop, preferredName: L("卷轴PDF", "Living Scroll PDF"), savedName: saved)
        if saved != old[0].lastPathComponent { defaults.set(old[0].lastPathComponent, forKey: desktopNameKey) }
        let custom = defaults.string(forKey: customKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return Self(defaultFolder: old[0], legacyFolders: old, customFolder: custom,
                    pendingExports: PendingCustomExports(defaults: defaults))
    }

    var usableCustomFolder: URL? {
        guard let customFolder else { return nil }
        let fm = FileManager.default, path = customFolder.path
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isReadableFile(atPath: path), fm.isWritableFile(atPath: path), fm.isExecutableFile(atPath: path) else { return nil }
        return customFolder
    }

    var folder: URL { usableCustomFolder ?? defaultFolder }

    /// Startup also checks both old Desktop names, even when the next export goes elsewhere.
    var recoveryFolders: [URL] {
        let current = folder
        return [current] + legacyFolders.filter { $0.standardizedFileURL.path != current.standardizedFileURL.path }
    }
}

struct ExportedFiles {
    let pdf: URL
    let usedDesktopFallback: Bool
    var unfinishedAtCustomFolder = false
    var png: URL { pdf.deletingPathExtension().appendingPathExtension("png") }
    var files: [URL] { [png, pdf] }
    var folder: URL { pdf.deletingLastPathComponent() }
}

import AppKit

enum ExportUI {
    static func path(_ folder: URL) -> String { (folder.path as NSString).abbreviatingWithTildeInPath }

    static func locationText(_ result: ExportedFiles) -> String {
        let path = path(result.folder)
        guard result.usedDesktopFallback else { return path }
        var text = path + "\n" + EditorCopy.desktopFallback(result.folder.lastPathComponent)
        if result.unfinishedAtCustomFolder {
            text += "\n" + L("原位置的文件还没写完，请使用上面文件夹里的这两份。", "The files in the original location are incomplete. Use the two files in the folder above.")
        }
        return text
    }

    static func reveal(_ files: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    @MainActor static func chooseLocation(startingAt folder: URL, for window: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.title = EditorCopy.exportLocation
        panel.prompt = L("选择文件夹", "Choose Folder")
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let choose = { (response: NSApplication.ModalResponse) in
            if response == .OK, let url = panel.url { ExportDestination.setCustomFolder(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: choose) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            choose(panel.runModal())
        }
    }
}

extension Exporter {
    /// The direct capture harness exits after reporting the PDF path. Reveal the same
    /// pair as the editor and print its location before handing that path back.
    static func export(_ image: CGImage, record: CaptureRecord) throws -> URL {
        let result = try export(image, record: record, to: .current())
        ExportUI.reveal(result.files)
        print("\(EditorCopy.exported)\n\(ExportUI.locationText(result))\nPNG: \(result.png.path)")
        return result.pdf
    }
}

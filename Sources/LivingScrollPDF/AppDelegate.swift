import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var picker: WindowPicker?
    private var session: CaptureSession?
    private var hotKeyRef: EventHotKeyRef?
    private var editors: [EditorWindow] = []
    private var opening: Set<UUID> = []
    private var quitAfterCapture = false
    private lazy var library = LibraryWindow(onDelete: { [weak self] id in
        self?.opening.remove(id)
        self?.editors.first { $0.documentID == id }?.close()
    }, onOpen: { [weak self] id in self?.openSavedCapture(id) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.menuBarIcon()
        installEditingMenu()
        buildMenu()
        registerHotKey()

        if let owner = ProcessInfo.processInfo.environment["JZ_TEST_OWNER"] {
            runEndToEndTest(owner: owner)
            return
        }

        Task {
            let failures = await Task.detached {
                let library = ScrollLibrary.shared
                var failures: [String] = []
                library.exportDestination.pendingExports?.recoverAvailable()
                for folder in Exporter.outputFolders {
                    do { try Exporter.recoverPendingExport(in: folder) }
                    catch { failures.append(EditorCopy.unfinishedExport + " " + error.localizedDescription) }
                }
                do { try library.prepare() }
                catch { failures.append(EditorCopy.libraryUnavailable + " " + error.localizedDescription) }
                return failures
            }.value
            if !failures.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = EditorCopy.failed
                alert.informativeText = failures.joined(separator: "\n")
                alert.runModal()
            }
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Small hanging scroll drawn as a template image, so it follows light and dark menu bars.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 14, width: 14, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1.4, width: 14, height: 2.6), xRadius: 1.3, yRadius: 1.3).fill()
            let paper = NSBezierPath(rect: NSRect(x: 4.5, y: 4, width: 9, height: 10))
            paper.lineWidth = 1.2
            NSColor.black.setStroke()
            paper.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 10.6, width: 4.5, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 4.5, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 5.4, width: 3.5, height: 1.6), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    private func buildMenu() {
            let menu = NSMenu()
            menu.delegate = self
            let start = NSMenuItem(title: L("开始截取（⌃⌥S）", "Start Capture (⌃⌥S)"), action: #selector(startCapture), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
            let library = NSMenuItem(title: EditorCopy.library, action: #selector(showLibrary), keyEquivalent: "")
            library.target = self
            menu.addItem(library)
            let choose = menu.addItem(withTitle: EditorCopy.exportLocation, action: #selector(chooseExportLocation), keyEquivalent: "")
            choose.target = self
            let folder = NSMenuItem(title: "", action: #selector(openFolder), keyEquivalent: "")
            folder.target = self
            menu.addItem(folder)
            let reset = menu.addItem(withTitle: "", action: #selector(restoreExportLocation), keyEquivalent: "")
            reset.target = self
            let layout = NSMenuItem(title: L("PDF 页面", "PDF Pages"), action: nil, keyEquivalent: "")
            let layouts = NSMenu()
            for (title, value) in [(L("一整页长 PDF（和长图一样，没有分页缝）", "One Long Page (seamless, like the image)"), Exporter.PDFLayout.long), (L("按 A4 分页（方便打印）", "A4 Pages (for printing)"), .a4)] {
                let item = NSMenuItem(title: title, action: #selector(chooseLayout(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value.rawValue
                item.state = Exporter.pdfLayout == value ? .on : .off
                layouts.addItem(item)
            }
            layout.submenu = layouts
            menu.addItem(layout)
            let preload = NSMenuItem(title: L("网页预加载提醒", "Web Page Preload Reminder"), action: nil, keyEquivalent: "")
            let reminders = NSMenu()
            for (title, enabled) in [(L("显示提醒", "Show Reminder"), true), (L("不再提示", "Don’t Show Again"), false)] {
                let item = NSMenuItem(title: title, action: #selector(choosePreloadReminder(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = enabled
                item.state = BrowserPreloadTip.enabled() == enabled ? .on : .off
                reminders.addItem(item)
            }
            preload.submenu = reminders
            menu.addItem(preload)
            let language = NSMenuItem(title: L("界面语言", "Language"), action: nil, keyEquivalent: "")
            let languages = NSMenu()
            for (title, value) in [(L("跟随系统", "Follow System"), Lang.system), ("中文", .zh), ("English", .en)] {
                let item = NSMenuItem(title: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = value.rawValue
                item.state = Lang.choice == value ? .on : .off
                languages.addItem(item)
            }
            language.submenu = languages
            menu.addItem(language)
            menu.addItem(.separator())
            let tip = NSMenuItem(title: L("请作者喝奶茶", "Buy the Author a Milk Tea"), action: #selector(showTip), keyEquivalent: "")
            tip.target = self
            menu.addItem(tip)
            let feedback = NSMenuItem(title: L("反馈问题 / 提意见", "Feedback"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let mail = NSMenuItem(title: L("发邮件：\(Links.email)", "Email: \(Links.email)"), action: #selector(openMail), keyEquivalent: "")
            mail.target = self
            sub.addItem(mail)
            let issues = NSMenuItem(title: L("在 GitHub 提 Issue", "Open an Issue on GitHub"), action: #selector(openFeedback), keyEquivalent: "")
            issues.target = self
            sub.addItem(issues)
            feedback.submenu = sub
            menu.addItem(feedback)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L("退出卷轴PDF", "Quit Living Scroll PDF"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem.menu = menu
        menuNeedsUpdate(menu)
        statusItem.button?.toolTip = L("卷轴PDF · 滚动长截图存 PDF", "Living Scroll PDF · scrolling capture to PDF")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.action == #selector(openFolder) }) else { return }
        let path = ExportUI.path(ScrollLibrary.shared.outputFolder)
        item.title = L("打开输出文件夹（\(path)）", "Open Output Folder (\(path))")
        item.toolTip = path
        let name = ExportDestination.savedDesktopName() ?? L("卷轴PDF", "Living Scroll PDF")
        menu.items.first { $0.action == #selector(restoreExportLocation) }?.title =
            L("恢复默认（桌面『\(name)』）", "Restore Default (“\(name)” on Desktop)")
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Lang(rawValue: raw) else { return }
        Lang.choice = value
        TipWindow.shared?.close()
        TipWindow.shared = nil
        buildMenu()
        installEditingMenu()
        editors.forEach { $0.refreshLanguage() }
    }

    @objc private func choosePreloadReminder(_ sender: NSMenuItem) {
        guard let enabled = sender.representedObject as? Bool else { return }
        BrowserPreloadTip.setEnabled(enabled)
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    /// Standard responder-chain actions also work inside a filename, search field or text annotation.
    private func installEditingMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: L("退出卷轴PDF", "Quit Living Scroll PDF"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        let items = NSMenu(title: L("编辑", "Edit"))
        items.addItem(withTitle: EditorCopy.undo, action: Selector(("undo:")), keyEquivalent: "z")
        let redo = items.addItem(withTitle: EditorCopy.redo, action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        items.addItem(.separator())
        items.addItem(withTitle: L("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        items.addItem(withTitle: L("复制", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        items.addItem(withTitle: L("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        items.addItem(withTitle: L("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = items
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    @objc private func showLibrary() { library.present() }

    /// Runs on the capture handoff queue before the editor can be closed.
    nonisolated static func saveCapture(_ image: CGImage, record: CaptureRecord, library: ScrollLibrary = .shared)
        -> (document: EditDocument, error: Error?) {
        let document = EditDocument(name: Exporter.fileStem(for: record), record: record)
        do { return (try library.save(document, original: image, categoryID: nil), nil) }
        catch { return (document, error) }
    }

    private func openSavedCapture(_ id: UUID) {
        if let open = editors.first(where: { $0.documentID == id }) { open.present(); return }
        guard opening.insert(id).inserted else { return }
        Task {
            defer { opening.remove(id) }
            do {
                let item = try await Task.detached(priority: .userInitiated) { try ScrollLibrary.shared.load(id) }.value
                guard opening.contains(id) else { return }
                present(item.document, original: item.original, categoryID: item.categoryID)
            } catch {
                let alert = NSAlert(error: error)
                if let window = library.window { alert.beginSheetModal(for: window, completionHandler: nil) }
                else { alert.runModal() }
            }
        }
    }

    func present(_ document: EditDocument, original: CGImage, categoryID: UUID? = nil, saveError: Error? = nil) {
        let id = document.id
        if let open = editors.first(where: { $0.documentID == id }) { open.present(); return }
        let editor = EditorWindow(document: document, original: original, categoryID: categoryID, saved: saveError == nil)
        editors.append(editor)
        editor.onOpenSection = { [weak self] id in self?.openSavedCapture(id) }
        editor.onClose = { [weak self, weak editor] in self?.editors.removeAll { $0 === editor } }
        editor.present()
        if let saveError { editor.showSaveProblem(saveError) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if session?.isFinishing == true {
            quitAfterCapture = true
            return .terminateLater
        }
        guard editors.contains(where: { $0.needsAttentionBeforeQuit() }) else { return .terminateNow }
        // Let AppKit enter the pending-termination state before replying to it.
        DispatchQueue.main.async { self.reviewBeforeQuit() }
        return .terminateLater
    }

    private func reviewBeforeQuit() {
        guard let editor = editors.first(where: { $0.needsAttentionBeforeQuit() }) else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        editor.present()
        editor.reviewBeforeClosing { closed in
            if closed { self.reviewBeforeQuit() }
            else { NSApp.reply(toApplicationShouldTerminate: false) }
        }
    }

    @objc func startCapture() {
        if let session {
            session.hotkey()
            return
        }
        guard picker == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = L("需要屏幕录制权限", "Screen recording permission needed")
            a.informativeText = L("在 系统设置 › 隐私与安全性 › 屏幕与系统录音 里打开「卷轴PDF」，然后重新打开卷轴PDF。", "Turn on Living Scroll PDF in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen the app.")
            a.runModal()
            return
        }
        let p = WindowPicker { [weak self] result in
            guard let self else { return }
            self.picker = nil
            guard let result else { return }
            let s = CaptureSession(pick: result) { [weak self] ended in
                guard let self, session === ended else { return }
                session = nil
                if quitAfterCapture {
                    quitAfterCapture = false
                    reviewBeforeQuit()
                }
            }
            self.session = s
            Task { @MainActor in await s.start() }
        }
        picker = p
        p.begin()
    }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Exporter.PDFLayout(rawValue: raw) else { return }
        Exporter.pdfLayout = value
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func showTip() { TipWindow.show() }

    @objc private func openFeedback() { NSWorkspace.shared.open(Links.issues) }

    @objc private func openMail() { NSWorkspace.shared.open(Links.mail) }

    @objc private func chooseExportLocation() {
        ExportUI.chooseLocation(startingAt: ScrollLibrary.shared.outputFolder)
    }

    @objc private func restoreExportLocation() { ExportDestination.setCustomFolder(nil) }

    @objc private func openFolder() {
        let destination = ScrollLibrary.shared.exportDestination, url = destination.folder
        if url == destination.defaultFolder { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        NSWorkspace.shared.open(url)
    }

    /// Developer check: capture the front window of `owner` with auto-scroll, then quit.
    private func runEndToEndTest(owner: String) {
        guard let w = WindowList.onScreen().first(where: { $0.owner == owner }) else {
            print("no window for \(owner)"); exit(2)
        }
        let top = CGFloat(Double(ProcessInfo.processInfo.environment["JZ_TEST_TOP"] ?? "60") ?? 60)
        let region = CGRect(x: w.bounds.minX, y: w.bounds.minY + top, width: w.bounds.width, height: w.bounds.height - top)
        let pick = PickResult(windowID: w.id, pid: w.pid, appName: w.owner, windowTitle: w.title,
                              windowFrame: w.bounds, region: region)
        let manualSeconds = Double(ProcessInfo.processInfo.environment["JZ_TEST_MANUAL_SECONDS"] ?? "")
        let s = CaptureSession(pick: pick, autoStart: manualSeconds == nil) { _ in exit(0) }
        session = s
        Task { @MainActor in await s.start() }
        if let manualSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + manualSeconds) { s.hotkey() }
        }
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared?.startCapture() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4A5A_484F), id: 1) // "JZHO"
        RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

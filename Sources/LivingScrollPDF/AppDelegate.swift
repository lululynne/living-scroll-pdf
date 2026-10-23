import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var picker: WindowPicker?
    private var session: CaptureSession?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = AppDelegate.menuBarIcon()
        buildMenu()
        registerHotKey()

        if let owner = ProcessInfo.processInfo.environment["JZ_TEST_OWNER"] {
            runEndToEndTest(owner: owner)
            return
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
            let start = NSMenuItem(title: L("开始截取（⌃⌥S）", "Start Capture (⌃⌥S)"), action: #selector(startCapture), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
            let folder = NSMenuItem(title: L("打开输出文件夹", "Open Output Folder"), action: #selector(openFolder), keyEquivalent: "")
            folder.target = self
            menu.addItem(folder)
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
        statusItem.button?.toolTip = L("卷轴PDF · 滚动长截图存 PDF", "Living Scroll PDF · scrolling capture to PDF")
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let value = Lang(rawValue: raw) else { return }
        Lang.choice = value
        TipWindow.shared?.close()
        TipWindow.shared = nil
        buildMenu()
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
                if self?.session === ended { self?.session = nil }
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

    @objc private func openFolder() {
        let url = Exporter.outputFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

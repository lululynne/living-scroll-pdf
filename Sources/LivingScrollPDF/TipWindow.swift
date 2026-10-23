import AppKit

enum Links {
    static let repo = URL(string: "https://github.com/lululynne/living-scroll-pdf")!
    static let issues = URL(string: "https://github.com/lululynne/living-scroll-pdf/issues")!
    static let email = "guanforlol@gmail.com"
    static let mail = URL(string: "mailto:guanforlol@gmail.com?subject=%E5%8D%B7%E8%BD%B4%E5%8F%8D%E9%A6%88")!
}

/// "请作者喝奶茶": the WeChat tip code and the add-friend code bundled in Resources.
final class TipWindow: NSWindow {
    static var shared: TipWindow?

    static func show() {
        let w = shared ?? TipWindow()
        shared = w
        NSApp.activate(ignoringOtherApps: true)
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("请作者喝奶茶", "Buy the author a milk tea")
        isReleasedWhenClosed = false

        let line = NSTextField(wrappingLabelWithString:
            L("如果卷轴PDF帮你省下了一下午拼截图的时间，扫码请作者喝杯奶茶吧，喵～\n有问题和意见直接联系：\(Links.email)，或者扫右边加微信",
              "If Living Scroll PDF saved you an afternoon of stitching screenshots, scan to buy the author a milk tea, meow~\nQuestions or ideas: \(Links.email), or scan the code on the right to add me on WeChat"))
        line.alignment = .center
        line.font = .systemFont(ofSize: 13)

        let codes = NSStackView(views: [("tip-wechat", L("微信打赏", "Tip via WeChat")), ("contact-wechat", L("加微信聊", "Add me on WeChat"))].compactMap { name, caption in
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
                  let image = NSImage(contentsOf: url) else { return nil }
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 240).isActive = true
            view.heightAnchor.constraint(equalToConstant: 320).isActive = true
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let column = NSStackView(views: [view, label])
            column.orientation = .vertical
            column.spacing = 6
            return column
        })
        codes.orientation = .horizontal
        codes.spacing = 24

        let stack = NSStackView(views: [codes, line])
        stack.orientation = .vertical
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        contentView = stack
    }
}

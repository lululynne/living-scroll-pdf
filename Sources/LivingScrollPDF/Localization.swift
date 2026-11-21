import Foundation

/// The interface speaks Chinese or English: it follows the system language unless the
/// user picked one in the menu.
enum Lang: String, CaseIterable {
    case system, zh, en

    static var choice: Lang {
        get { Lang(rawValue: UserDefaults.standard.string(forKey: "uiLanguage") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "uiLanguage") }
    }

    static var isChinese: Bool {
        if let forced = ProcessInfo.processInfo.environment["LSP_LANG"] { return forced.hasPrefix("zh") }
        switch choice {
        case .zh: return true
        case .en: return false
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// Picks the string for the current interface language.
func L(_ zh: String, _ en: String) -> String { Lang.isChinese ? zh : en }

enum EditorCopy {
    static var preparing: String { L("正在整理长截图…", "Preparing screenshot…") }
    static var editor: String { L("编辑长截图", "Edit Screenshot") }
    static var library: String { L("我的长截图", "My Screenshots") }
    static var name: String { L("文件名", "Filename") }
    static var category: String { L("分类", "Category") }
    static var uncategorized: String { L("未分类", "Uncategorized") }
    static var newCategory: String { L("新建分类…", "New Category…") }
    static var categoryName: String { L("分类名称", "Category name") }
    static var create: String { L("创建", "Create") }
    static var save: String { L("保存", "Save") }
    static var export: String { L("导出 PNG 和 PDF", "Export PNG & PDF") }
    static var saving: String { L("正在保存…", "Saving…") }
    static var exporting: String { L("正在导出…", "Exporting…") }
    static var saved: String { L("已保存到我的长截图", "Saved to My Screenshots") }
    static var savedExportFailed: String { L("编辑已保存，导出失败", "Edits saved. Export failed.") }
    static var failed: String { L("操作未完成", "Couldn’t complete the operation") }
    static var adjustColor: String { L("颜色", "Color") }
    static var lineWidth: String { L("粗细", "Width") }
    static var fontSize: String { L("字号", "Type size") }
    static var undo: String { L("撤销", "Undo") }
    static var redo: String { L("重做", "Redo") }
    static var delete: String { L("删除选中图层", "Delete Selected Layer") }
    static var fit: String { L("适合宽度", "Fit Width") }
    static var zoomIn: String { L("放大", "Zoom In") }
    static var zoomOut: String { L("缩小", "Zoom Out") }
    static var pasteImage: String { L("粘贴图片", "Paste Image") }
    static var invalidImage: String { L("图片无法读取。", "The image could not be read.") }
    static var emptyPasteboard: String { L("剪贴板里没有可插入的图片。", "The clipboard contains no image to insert.") }
    static var unsaved: String { L("保存这张长截图的更改？", "Save changes to this screenshot?") }
    static var discard: String { L("放弃更改", "Discard Changes") }
    static var cancel: String { L("取消", "Cancel") }
    static var partial: String { L("未完成截图", "Partial capture") }

    static func title(for kind: EditLayerKind?) -> String {
        switch kind {
        case nil: return L("选择", "Select")
        case .pen: return L("画笔", "Pen")
        case .highlighter: return L("荧光笔", "Highlighter")
        case .rectangle: return L("矩形", "Rectangle")
        case .ellipse: return L("椭圆", "Ellipse")
        case .arrow: return L("箭头", "Arrow")
        case .mosaic: return L("马赛克", "Mosaic")
        case .text: return L("文字", "Text")
        case .image: return L("插入图片…", "Insert Image…")
        }
    }
}

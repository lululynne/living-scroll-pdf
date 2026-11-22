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
    static var export: String { L("导出（PNG + PDF）", "Export (PNG + PDF)") }
    static var exportLocation: String { L("导出位置…", "Export Location…") }
    static var openFolder: String { L("打开文件夹", "Open Folder") }
    static var exported: String { L("已存好 PNG 和 PDF 各一份", "Saved one PNG and one PDF") }
    static func desktopFallback(_ name: String) -> String {
        L("原来选的文件夹找不到了，这次存到了桌面『\(name)』", "The chosen folder is unavailable. This export was saved to “\(name)” on your Desktop.")
    }
    static var saving: String { L("正在保存…", "Saving…") }
    static var exporting: String { L("正在导出…", "Exporting…") }
    static var saved: String { L("已保存到我的长截图", "Saved to My Screenshots") }
    static var savedCopy: String { L("另一份编辑也已保留，当前版本已另存为副本", "Another edit was saved. This version is saved as a copy.") }
    static var librarySaveFailed: String { L("图库保存失败，仍可导出。", "Couldn’t save to the library. You can still export.") }
    static var libraryUnavailable: String { L("检查「我的长截图」时遇到问题。", "My Screenshots needs attention.") }
    static var unfinishedExport: String { L("未能恢复上次导出。", "Couldn’t finish the previous export.") }
    static var exportedWithoutLibrary: String { L("文件已导出，图库未更新", "Files exported. The library could not be updated.") }
    static var redactionExported: String { L("这两份文件都已打码。", "Both files are redacted.") }
    static var privateOriginalNotice: String { L("未打码的原图保存在本机的「我的长截图」。选中截图，点「删除截图」即可删除原图和编辑记录。", "The unredacted original is in My Screenshots on this Mac. Select the capture and choose Delete Screenshot to remove its original and edits.") }
    static var deleteCapture: String { L("删除截图", "Delete Screenshot") }
    static func confirmDeleteCapture(_ name: String) -> String { L("删除「\(name)」？", "Delete “\(name)”?") }
    static var deleteCaptureDetails: String { L("将永久删除图库里的原图和全部编辑记录。已导出的文件会保留。", "This permanently deletes the library original and all its edits. Exported files are kept.") }
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
    static var cropSection: String { L("截一段", "Crop Section") }
    static var cropHint: String {
        L("点一下定开始线，往下滚到要结束的地方再点一下", "Click the start line, then scroll and click the end.")
    }
    static var cropTooShort: String { L("选得太短了", "Selection is too short") }
    static var saveSection: String { L("另存为新长截图", "Save as New Screenshot") }
    static var savingSection: String { L("正在保存新长截图…", "Saving new screenshot…") }

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

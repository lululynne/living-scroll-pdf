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

import Foundation

enum Membership {
    enum Feature { case cropSection }

    /// Development and acceptance builds are unlocked by default. Connect this
    /// decision to the license state when license/paddle-sandbox is integrated.
    static func allows(_ feature: Feature, defaults: UserDefaults = .standard,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch feature {
        case .cropSection:
            if let override = environment["LSP_MEMBERSHIP_ACTIVE"] {
                return ["1", "true", "yes", "on"].contains(override.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
            return defaults.object(forKey: "membershipActive") == nil || defaults.bool(forKey: "membershipActive")
        }
    }

    struct Required: LocalizedError {
        var errorDescription: String? { L("截一段是会员功能", "Crop Section is a member feature") }
    }
}

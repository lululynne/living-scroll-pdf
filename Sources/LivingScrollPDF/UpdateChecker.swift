import Foundation

struct AppRelease: Codable, Equatable {
    let version: String
    let date: String
    let downloadURL: URL
    let notesZH: [String]
    let notesEN: [String]
    let minMacOS: String
    let published: Bool?

    enum CodingKeys: String, CodingKey {
        case version, date
        case downloadURL = "download_url"
        case notesZH = "notes_zh"
        case notesEN = "notes_en"
        case minMacOS = "min_macos"
        case published
    }
}

struct UpdateManifest: Codable, Equatable {
    let latest: AppRelease
    let releases: [AppRelease]
}

protocol UpdateNetworking {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateNetworking {}

enum UpdateCheckResult: Equatable {
    case latest(current: String)
    case available(AppRelease, current: String)
}

final class UpdateChecker {
    static let defaultBaseURL = URL(string: "https://scroll.mymomentsmaker.com")!
    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let lastCheckKey = "update.lastCheck"
    static let skippedVersionKey = "update.skippedVersion"

    private let baseURL: URL
    private let session: UpdateNetworking
    private let defaults: UserDefaults
    private let currentVersion: String

    init(baseURL: URL = UpdateChecker.defaultBaseURL,
         session: UpdateNetworking = URLSession.shared,
         defaults: UserDefaults = .standard,
         currentVersion: String? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.defaults = defaults
        self.currentVersion = currentVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")
    }

    var changelogURL: URL { baseURL.appendingPathComponent("changelog") }
    var lastCheckDate: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }
    var skippedVersion: String? { defaults.string(forKey: Self.skippedVersionKey) }

    func shouldCheckAutomatically(now: Date = Date()) -> Bool {
        guard let lastCheckDate else { return true }
        return now.timeIntervalSince(lastCheckDate) >= Self.checkInterval
    }

    func markChecked(at date: Date = Date()) {
        defaults.set(date, forKey: Self.lastCheckKey)
    }

    func skip(version: String) {
        defaults.set(version, forKey: Self.skippedVersionKey)
    }

    func check() async throws -> UpdateCheckResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("version.json"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        let release = manifest.latest
        guard release.published ?? true else { return .latest(current: currentVersion) }
        if Self.compareVersions(release.version, currentVersion) == .orderedDescending {
            return .available(release, current: currentVersion)
        }
        return .latest(current: currentVersion)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericParts(lhs)
        let right = numericParts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericParts(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}

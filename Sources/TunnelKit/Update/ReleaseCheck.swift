import Foundation

/// A version like 1.2.3 or v1.2.3-beta.1, ordered by Semantic Versioning 2.0 precedence (build
/// metadata after `+` is ignored).
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated pre-release identifiers; empty for a release.
    public var prerelease: [String]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            pre = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.contains(where: \.isEmpty) else { return nil }
            text = String(text[..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        // "0.4" counts as 0.4.0; anything else that isn't numbers isn't a version.
        guard (1...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
        prerelease = pre
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A pre-release comes before its release.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true  // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The parts of GitHub's "latest release" response the update check uses.
public struct Release: Equatable, Sendable {
    public var version: SemanticVersion
    public var tag: String
    /// The release page, for Release Notes.
    public var pageURL: URL
    /// The .dmg to download, when the release has one.
    public var dmgURL: URL?

    /// GitHub's `GET /repos/{owner}/{repo}/releases/latest` body. Nil for anything that isn't a
    /// published release with a version tag.
    public init?(gitHubJSON data: Data) {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
        }
        struct Body: Decodable {
            var tag_name: String
            var html_url: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              body.draft != true, body.prerelease != true,
              let version = SemanticVersion(body.tag_name) else { return nil }
        self.version = version
        tag = body.tag_name
        pageURL = body.html_url
        dmgURL = body.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
    }
}

public enum ReleaseCheck {
    public static let latestURL = URL(string: "https://api.github.com/repos/rattamnoon/portkeep/releases/latest")!
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let upgradeCommand = "brew upgrade --cask portkeep"

    /// `release` when it is newer than the running `current` version.
    public static func newer(_ release: Release?, than current: String) -> Release? {
        guard let release, let running = SemanticVersion(current), running < release.version else { return nil }
        return release
    }

    /// A day has passed since the last check (or there never was one, or the clock went back).
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// Installed by Homebrew: in /Applications with a portkeep folder in Homebrew's Caskroom.
    public static func isHomebrewInstall(appPath: String, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        guard appPath.hasPrefix("/Applications/") else { return false }
        return fileExists("/opt/homebrew/Caskroom/portkeep") || fileExists("/usr/local/Caskroom/portkeep")
    }
}

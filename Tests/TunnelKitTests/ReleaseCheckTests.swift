import Foundation
import Testing
@testable import TunnelKit

private func v(_ text: String) -> SemanticVersion { SemanticVersion(text)! }

@Test func parsesVersions() {
    #expect(v("v0.4.0") == v("0.4.0"))
    #expect(v("0.4") == v("0.4.0"))
    #expect(v("1.2.3-beta.1+build.5").prerelease == ["beta", "1"])
    #expect(v("1.2.3+build").description == "1.2.3")
    #expect(SemanticVersion("latest") == nil)
    #expect(SemanticVersion("1.2.3.4") == nil)
    #expect(SemanticVersion("1.x") == nil)
    #expect(SemanticVersion("1.2.3-") == nil)
}

@Test func ordersBySemverPrecedence() {
    // The example chain from semver.org §11.
    let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                 "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0"].map(v)
    for (a, b) in zip(chain, chain.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
    #expect(v("0.10.0") > v("0.9.9"), "numbers, not text")
    #expect(!(v("0.4.0") < v("v0.4.0")))
}

private let latest = Data("""
    {"tag_name": "v0.5.0", "html_url": "https://github.com/rattamnoon/portkeep/releases/tag/v0.5.0",
     "draft": false, "prerelease": false,
     "assets": [{"name": "Portkeep-0.5.0.dmg.sha256", "browser_download_url": "https://example.com/a.sha256"},
                {"name": "Portkeep-0.5.0.dmg", "browser_download_url": "https://example.com/Portkeep-0.5.0.dmg"}]}
    """.utf8)

@Test func readsGitHubsLatestRelease() throws {
    let release = try #require(Release(gitHubJSON: latest))
    #expect(release.version == v("0.5.0"))
    #expect(release.pageURL.absoluteString.hasSuffix("/v0.5.0"))
    #expect(release.dmgURL?.lastPathComponent == "Portkeep-0.5.0.dmg")
    #expect(Release(gitHubJSON: Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    #expect(Release(gitHubJSON: Data(#"{"tag_name": "nightly", "html_url": "https://x"}"#.utf8)) == nil)
    #expect(Release(gitHubJSON: Data(#"{"tag_name": "v9.0.0", "html_url": "https://x", "prerelease": true}"#.utf8)) == nil)
}

@Test func offersOnlyNewerReleases() {
    let release = Release(gitHubJSON: latest)
    #expect(ReleaseCheck.newer(release, than: "0.4.0") != nil)
    #expect(ReleaseCheck.newer(release, than: "0.5.0") == nil)
    #expect(ReleaseCheck.newer(release, than: "0.6.0-beta.1") == nil)
    #expect(ReleaseCheck.newer(release, than: "dev") == nil, "an unversioned build never nags")
    #expect(ReleaseCheck.newer(nil, than: "0.1.0") == nil)
}

@Test func checksOncePerDay() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ReleaseCheck.isDue(lastCheck: nil, now: now))
    #expect(!ReleaseCheck.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    #expect(ReleaseCheck.isDue(lastCheck: now.addingTimeInterval(-ReleaseCheck.interval), now: now))
    #expect(ReleaseCheck.isDue(lastCheck: now.addingTimeInterval(600), now: now), "clock went back")
}

@Test func detectsHomebrewInstalls() {
    #expect(ReleaseCheck.isHomebrewInstall(appPath: "/Applications/Portkeep.app") { $0 == "/opt/homebrew/Caskroom/portkeep" })
    #expect(ReleaseCheck.isHomebrewInstall(appPath: "/Applications/Portkeep.app") { $0 == "/usr/local/Caskroom/portkeep" })
    #expect(!ReleaseCheck.isHomebrewInstall(appPath: "/Applications/Portkeep.app") { _ in false })
    #expect(!ReleaseCheck.isHomebrewInstall(appPath: "/Users/me/Downloads/Portkeep.app") { _ in true })
}

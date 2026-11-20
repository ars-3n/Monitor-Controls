import Foundation
import Testing
@testable import AppUpdate

private let source = UpdateSource(repository: "ars-3n/Monitor-Controls", asset: "MonitorControls.zip")

private func payload(tag: String = "v1.0.3-4abbee934948",
                     page: String = "https://github.com/ars-3n/Monitor-Controls/releases/tag/v1.0.3-4abbee934948",
                     asset: String = "MonitorControls.zip",
                     download: String = "https://github.com/ars-3n/Monitor-Controls/releases/download/v1.0.3-4abbee934948/MonitorControls.zip",
                     digest: String? = "sha256:8549c4ce3eeaa4174250a0e53b2931af44ab73a43cbfb2a84abccf334510e3ee",
                     draft: Bool = false, prerelease: Bool = false) -> Data {
    var file: [String: Any] = ["name": asset, "browser_download_url": download, "size": 1078900]
    if let digest { file["digest"] = digest }
    let release: [String: Any] = ["tag_name": tag, "html_url": page, "draft": draft, "prerelease": prerelease,
                                  "name": "Monitor Controls", "assets": [file]]
    return try! JSONSerialization.data(withJSONObject: release)
}

@Test func versionsCompareByNumberNotByText() throws {
    let old = try #require(AppVersion("1.0.9"))
    let new = try #require(AppVersion("1.0.10"))
    #expect(old < new)
    #expect(try #require(AppVersion("1.2")) > new)
    #expect(try #require(AppVersion("2")) > #require(AppVersion("1.99.99")))
    #expect(AppVersion("1.0") == AppVersion("1.0.0"))
    #expect(try #require(AppVersion("1")) < #require(AppVersion("1.0.1")))
    #expect(try #require(AppVersion("1.0.3")).description == "1.0.3")
}

@Test func malformedVersionsAreRejected() {
    for text in ["", "1.", ".1", "1..2", "v1.0", "1.0-beta", "1.0.0.0.0", "1.-2", "١.٢", "1.0 ", "9999999.0"] {
        #expect(AppVersion(text) == nil, "\(text)")
    }
}

@Test func latestReleaseIsReadFromGitHubsAnswer() throws {
    let release = try source.release(from: payload())
    #expect(release.version == AppVersion("1.0.3"))
    #expect(release.page.absoluteString == "https://github.com/ars-3n/Monitor-Controls/releases/tag/v1.0.3-4abbee934948")
    #expect(release.download.absoluteString.hasSuffix("/v1.0.3-4abbee934948/MonitorControls.zip"))
    #expect(release.sha256 == "8549c4ce3eeaa4174250a0e53b2931af44ab73a43cbfb2a84abccf334510e3ee")
    #expect(try source.release(from: payload(tag: "v2.0", digest: nil)).sha256 == nil)
    #expect(try source.release(from: payload(digest: "md5:abc")).sha256 == nil)
}

@Test func releasesThatPointElsewhereAreRejected() {
    let bad: [Data] = [
        payload(download: "https://example.com/ars-3n/Monitor-Controls/releases/download/v1/MonitorControls.zip"),
        payload(download: "http://github.com/ars-3n/Monitor-Controls/releases/download/v1/MonitorControls.zip"),
        payload(download: "https://github.com/someone-else/Monitor-Controls/releases/download/v1/MonitorControls.zip"),
        payload(download: "https://github.com/ars-3n/Monitor-Controls/releases/download/../../../other/repo/MonitorControls.zip"),
        payload(download: "https://github.com/ars-3n/Monitor-Controls/releases/download/v1/Other.zip"),
        payload(download: "https://github.com/ars-3n/Monitor-Controls/releases/download/v1/MonitorControls.zip?x=1"),
        payload(page: "https://example.com/phish"),
        payload(asset: "Other.zip"),
        payload(tag: "1.0.3"),
        payload(tag: "vnext"),
        payload(draft: true),
        payload(prerelease: true),
        Data("not json".utf8),
        Data(#"{"message":"Not Found"}"#.utf8),
    ]
    for data in bad {
        #expect(throws: UpdateError.unreadableRelease) { try source.release(from: data) }
    }
}

@Test func installerOnlyOffersNewerVersionsAndExplainsWhyItCannotInstall() throws {
    let app = URL(fileURLWithPath: "/Applications/Monitor Controls.app")
    let version = try #require(AppVersion("1.0.3"))
    let signed = UpdateInstaller(source: source, app: app, currentVersion: version, requirement: "identifier \"x\"")
    #expect(signed.installBlocker == nil)
    #expect(!signed.isNewer(try source.release(from: payload())))
    #expect(signed.isNewer(try source.release(from: payload(tag: "v1.0.4-abc"))))
    #expect(!signed.isNewer(try source.release(from: payload(tag: "v1.0.2-abc"))))

    let adHoc = UpdateInstaller(source: source, app: app, currentVersion: version, requirement: nil)
    #expect(adHoc.installBlocker == .unsigned)
    let moved = UpdateInstaller(source: source, app: URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Monitor Controls.app"),
                                currentVersion: version, requirement: "identifier \"x\"")
    #expect(moved.installBlocker == .translocated)
}

@Test func aBundleWithNoSignatureDoesNotPassTheSignerCheck() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let contents = folder.appendingPathComponent("Fake.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("Fake"))
    #expect(!CodeIdentity.bundle(at: folder.appendingPathComponent("Fake.app"), satisfies: "identifier \"com.ars3n.DeskControls\""))
    #expect(!CodeIdentity.bundle(at: folder.appendingPathComponent("Fake.app"), satisfies: "this is not a requirement"))
}

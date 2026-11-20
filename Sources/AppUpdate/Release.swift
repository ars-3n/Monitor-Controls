import Foundation

/// A dotted numeric version such as 1.0.3.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    private let parts: [Int]

    public init?(_ text: String) {
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(fields.count) else { return nil }
        var parts: [Int] = []
        for field in fields {
            guard (1...6).contains(field.count), field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(field) else { return nil }
            parts.append(number)
        }
        // 1.0 and 1.0.0 name the same version.
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }
}

public struct AvailableRelease: Equatable, Sendable {
    public let version: AppVersion
    public let page: URL
    public let download: URL
    /// Lowercase hex SHA-256 of the download, when GitHub reports one.
    public let sha256: String?
}

/// The GitHub repository that publishes the app, and the file to take from a release.
public struct UpdateSource: Equatable, Sendable {
    public let repository: String
    public let asset: String

    public init(repository: String, asset: String) {
        self.repository = repository
        self.asset = asset
    }

    public var page: URL { URL(string: "https://github.com/\(repository)")! }
    public var latestRelease: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// Reads GitHub's description of a release. Rejects one that points
    /// anywhere other than this repository's own release pages.
    public func release(from data: Data) throws -> AvailableRelease {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
                let digest: String?
            }
            let tag_name: String
            let html_url: String
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              // Tags look like v1.0.3-4abbee934948.
              payload.tag_name.hasPrefix("v"),
              let number = payload.tag_name.dropFirst().split(separator: "-", omittingEmptySubsequences: false).first,
              let version = AppVersion(String(number)),
              let page = releaseURL(payload.html_url, under: "releases/tag/"),
              let file = payload.assets.first(where: { $0.name == asset }),
              let download = releaseURL(file.browser_download_url, under: "releases/download/"),
              download.lastPathComponent == asset else { throw UpdateError.unreadableRelease }

        var sha256: String?
        if let digest = file.digest?.lowercased(), digest.hasPrefix("sha256:") {
            let hex = String(digest.dropFirst("sha256:".count))
            if hex.count == 64, hex.allSatisfy(\.isHexDigit) { sha256 = hex }
        }
        return AvailableRelease(version: version, page: page, download: download, sha256: sha256)
    }

    private func releaseURL(_ text: String, under path: String) -> URL? {
        let prefix = "https://github.com/\(repository)/\(path)"
        guard text.lowercased().hasPrefix(prefix.lowercased()), text.count > prefix.count,
              let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.contains("..") else { return nil }
        return url
    }
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case offline
    case busy
    case unreadableRelease
    case downloadFailed
    case damagedDownload
    case differentSigner
    case notNewer
    case unsigned
    case translocated
    case cannotReplace(String)

    public var errorDescription: String? {
        switch self {
        case .offline: "GitHub could not be reached. Check your connection and try again."
        case .busy: "GitHub is limiting requests from this network. Try again in a few minutes."
        case .unreadableRelease: "The latest release on GitHub could not be read."
        case .downloadFailed: "The update could not be downloaded. Try again."
        case .damagedDownload: "The download was damaged, so it was not installed. Try again."
        case .differentSigner: "The download is not signed with the same certificate as this app, so it was not installed."
        case .notNewer: "The download is not newer than this version, so it was not installed."
        case .unsigned: "This copy has no signing certificate, so it cannot verify an update. Download the new version from the release page."
        case .translocated: "Move Monitor Controls to the Applications folder and open it from there. Then it can update itself."
        case .cannotReplace(let folder): "Monitor Controls could not replace itself in \(folder). Download the new version from the release page."
        }
    }
}

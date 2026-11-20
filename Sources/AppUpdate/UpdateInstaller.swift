import CryptoKit
import Foundation

/// Finds the latest release and replaces the app with it. Nothing here runs
/// on its own. The app calls it when the user asks.
public struct UpdateInstaller: Sendable {
    public let source: UpdateSource
    public let app: URL
    public let currentVersion: AppVersion
    /// The signature every update must carry. Nil when this copy is ad hoc.
    public let requirement: String?
    private let session: URLSession

    private static let largestDownload = 100 * 1024 * 1024

    public init(source: UpdateSource, app: URL, currentVersion: AppVersion, requirement: String?) {
        self.source = source
        self.app = app
        self.currentVersion = currentVersion
        self.requirement = requirement
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 300
        configuration.httpAdditionalHeaders = ["User-Agent": "MonitorControls/\(currentVersion)"]
        session = URLSession(configuration: configuration)
    }

    public func latestRelease() async throws -> AvailableRelease {
        var request = URLRequest(url: source.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.offline
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try source.release(from: data)
        case 403, 429: throw UpdateError.busy
        default: throw UpdateError.unreadableRelease
        }
    }

    public func isNewer(_ release: AvailableRelease) -> Bool { release.version > currentVersion }

    /// Why this copy cannot replace itself, if it cannot.
    public var installBlocker: UpdateError? {
        if requirement == nil { return .unsigned }
        // macOS runs a quarantined app from a read-only copy elsewhere.
        if app.path.contains("/AppTranslocation/") { return .translocated }
        return nil
    }

    /// Downloads the release, checks it, and puts it where the app is now.
    /// The running copy keeps working until it quits.
    public func install(_ release: AvailableRelease) async throws {
        if let installBlocker { throw installBlocker }
        guard let requirement else { throw UpdateError.unsigned }
        let files = FileManager.default
        let folder = app.deletingLastPathComponent()
        // A folder on the app's own volume, so the swap below is a rename.
        guard let staging = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                           appropriateFor: app, create: true) else {
            throw UpdateError.cannotReplace(folder.path)
        }
        defer { try? files.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("update.zip")
        do {
            let (file, response) = try await session.download(from: release.download)
            defer { try? files.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.downloadFailed }
            try files.moveItem(at: file, to: archive)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.downloadFailed
        }
        guard let size = try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= Self.largestDownload,
              let contents = try? Data(contentsOf: archive, options: .mappedIfSafe) else { throw UpdateError.damagedDownload }
        if let expected = release.sha256 {
            let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError.damagedDownload }
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, unpacked.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        do { try unzip.run() } catch { throw UpdateError.damagedDownload }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0,
              let items = try? files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey]),
              items.count == 1, let update = items.first, update.pathExtension == "app",
              (try? update.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
            throw UpdateError.damagedDownload
        }

        // The signature covers the whole bundle, so everything read from it
        // after this check is the signer's own.
        guard CodeIdentity.bundle(at: update, satisfies: requirement) else { throw UpdateError.differentSigner }
        guard let text = Bundle(url: update)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(text), version > currentVersion else { throw UpdateError.notNewer }

        do {
            _ = try files.replaceItemAt(app, withItemAt: update)
        } catch {
            throw UpdateError.cannotReplace(folder.path)
        }
    }

    /// Opens the app again once this process has exited.
    public func relaunch() throws {
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
                            "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        waiter.standardInput = FileHandle.nullDevice
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        try waiter.run()
    }
}

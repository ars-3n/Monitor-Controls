import AppKit
import AppUpdate
import Observation

/// Checks for a new release only when the user asks. Nothing here runs on a timer.
@MainActor @Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case current
        case available(AvailableRelease)
        case installing(AvailableRelease)
        case failed(String, AvailableRelease?)
    }

    private(set) var state: State = .idle
    let version: String
    @ObservationIgnored private let installer: UpdateInstaller?

    init(bundle: Bundle = .main) {
        let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        version = text ?? "unknown"
        installer = text.flatMap(AppVersion.init).map {
            UpdateInstaller(source: UpdateSource(repository: "ars-3n/Monitor-Controls", asset: "MonitorControls.zip"),
                            app: bundle.bundleURL, currentVersion: $0,
                            requirement: CodeIdentity.requirementOfRunningApp())
        }
    }

    /// Why this copy cannot install an update itself, in words for the user.
    var installBlocker: String? { installer?.installBlocker?.errorDescription }

    func check() {
        if case .checking = state { return }
        if case .installing = state { return }
        guard let installer else {
            state = .failed("This build has no version number, so it cannot check for updates.", nil)
            return
        }
        state = .checking
        Task {
            do {
                let release = try await installer.latestRelease()
                state = installer.isNewer(release) ? .available(release) : .current
            } catch {
                state = .failed(Self.message(for: error), nil)
            }
        }
    }

    func install(_ release: AvailableRelease) {
        guard let installer else { return }
        switch state {
        case .available(release), .failed(_, release?): break
        default: return
        }
        state = .installing(release)
        Task {
            do {
                try await installer.install(release)
            } catch {
                state = .failed(Self.message(for: error), release)
                return
            }
            do {
                try installer.relaunch()
                NSApp.terminate(nil)
            } catch {
                state = .failed("Version \(release.version) is installed. Quit Monitor Controls and open it again to use it.", nil)
            }
        }
    }

    func openPage(of release: AvailableRelease) { NSWorkspace.shared.open(release.page) }

    private static func message(for error: Error) -> String {
        (error as? UpdateError)?.errorDescription ?? "The update could not be completed. Try again."
    }
}

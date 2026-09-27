import AppKit
import CryptoKit
import Foundation

/// An update replaces the executable, and macOS can keep a stale Accessibility entry
/// that shows ELTransfer as enabled while denying it. Reset that entry once per update.
@MainActor
enum AccessibilityRecovery {
    nonisolated static let bundleIdentifier = "com.duuberian.ELTransfer"
    static let defaultsKey = "accessibilityResetExecutableSHA256"

    /// Consume an executable change before recovery, including failed attempts.
    /// A fresh installation, a valid grant, and ordinary relaunches never reset.
    static func prepare(executable: URL, defaults: UserDefaults = .standard,
                        readTrust: () -> Bool, reset: () async throws -> Void) async throws -> Bool {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: defaultsKey)
        guard previous != fingerprint else { return false }
        defaults.set(fingerprint, forKey: defaultsKey)
        // Persist before invoking tccutil so a crash or failed reset cannot loop.
        guard defaults.synchronize() else { throw RecoveryError.cannotRecordAttempt }
        guard previous != nil, !readTrust() else { return false }
        try await reset()
        return true
    }

    /// TCC can cache this process before the reset. Start a fresh process after a
    /// successful reset so the app reappears in Settings. prepare persists the
    /// fingerprint first, so the new process cannot loop.
    static func recoverAfterUpdate() async throws -> Bool {
        guard let executable = Bundle.main.executableURL, isInstalledApp else { return false }
        guard try await prepare(executable: executable, readTrust: { AXIsProcessTrusted() },
                                reset: resetApproval) else { return false }
        try await restart()
        return true
    }

    private static var isInstalledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == bundleIdentifier
    }

    static func resetApproval() async throws {
        // Scope the reset to this app and this permission; never reset the TCC database.
        guard isInstalledApp else { throw RecoveryError.notInstalled }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", bundleIdentifier]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RecoveryError.resetFailed }
        }.value
    }

    static func restart() async throws {
        guard isInstalledApp else { throw RecoveryError.notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        NSApp.terminate(nil)
    }

    enum RecoveryError: LocalizedError {
        case notInstalled, resetFailed, cannotRecordAttempt
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Open the installed ELTransfer app in Applications to repair access."
            case .resetFailed: "macOS could not reset access. In Accessibility Settings, remove ELTransfer with −, then add the app from Applications with +."
            case .cannotRecordAttempt: "ELTransfer could not save the recovery state, so Accessibility was not reset. Open Accessibility Settings to review access."
            }
        }
    }
}

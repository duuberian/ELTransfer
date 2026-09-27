import AppKit
import Combine
import Network
import Sparkle

/// ELTransfer schedules checks; Sparkle owns signed downloads, replacement and relaunch. Only the
/// app bundle is replaced; cursor settings in UserDefaults are preserved.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var availableVersion: String?
    @Published private(set) var updateNotification: String?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "Development build"
    let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    @Published private(set) var updateStatus: String?
    @Published private(set) var lastCheckFailed = false
    private var remindedBuild: String?
    @Published private var hasPendingReminder = false

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
    )
    private var started = false
    private var schedule = UpdateCheckSchedule()
    private let pathMonitor = NWPathMonitor()
    private var online = false
    private var checkTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    override init() {
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func start() {
        // `swift run` is not an installed app bundle.
        guard !started, Bundle.main.bundleIdentifier == "com.duuberian.ELTransfer",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        started = true
        confirmPreviousInstallation()
        // One scheduler avoids duplicate Sparkle and connectivity-triggered checks.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.updateCheckInterval = UpdateCheckSchedule.interval
        controller.startUpdater()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let restored = connected && !online
                online = connected
                if restored { schedule.connectionRestored(now: Date()) }
                checkIfDue()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.duuberian.ELTransfer.update-connectivity"))
        checkTimer = Timer.scheduledTimer(withTimeInterval: UpdateCheckSchedule.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard started, schedule.isDue(now: Date(), online: online,
                                      canCheck: canCheckForUpdates && !hasPendingReminder) else { return }
        schedule.begin()
        controller.updater.checkForUpdatesInBackground()
    }

    nonisolated func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        UpdateReleasePolicy.bestItem(in: appcast.items, currentVersion: currentVersion,
                                     currentBuild: currentBuild) ?? SUAppcastItem.empty()
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                             updateCheck: SPUUpdateCheck) throws {
        guard UpdateReleasePolicy.allows(version: item.displayVersionString, build: item.versionString,
                                         currentVersion: currentVersion, currentBuild: currentBuild) else {
            throw NSError(domain: "com.duuberian.ELTransfer.update-policy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This release is older than the installed app and cannot be installed."])
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Task { @MainActor [weak self] in self?.schedule.succeeded(now: Date()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        Task { @MainActor [weak self] in self?.schedule.finished(now: Date()) }
    }

    var isAvailable: Bool { started }

    func checkForUpdates() {
        guard canCheckForUpdates || hasPendingReminder else { return }
        lastCheckFailed = false
        updateStatus = "Checking for updates…"
        dismissUpdateNotification()
        schedule.begin()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let build = update.versionString
        DispatchQueue.main.async { [weak self] in
            self?.recordUpdate(version: version, build: build, scheduled: !handleShowingUpdate)
        }
    }

    func recordUpdate(version: String, build: String, scheduled: Bool) {
        lastCheckFailed = false
        updateStatus = "Version \(version) is ready. Choose Update, then Install Update in the macOS updater."
        latestVersion = version
        availableVersion = version
        hasPendingReminder = scheduled
        if remindedBuild != build {
            remindedBuild = build
            updateNotification = version
        }
    }

    func dismissUpdateNotification() {
        updateNotification = nil
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        DispatchQueue.main.async { [weak self] in
            self?.latestVersion = version
            self?.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let item = (error as NSError).userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
        let version = item?.displayVersionString
        DispatchQueue.main.async { [weak self] in
            self?.recordNoUpdate(latestVersion: version)
        }
    }

    func recordNoUpdate(latestVersion: String?) {
        lastCheckFailed = false
        updateStatus = "No newer compatible update is available."
        self.latestVersion = latestVersion
        availableVersion = nil
        hasPendingReminder = false
        remindedBuild = nil
        dismissUpdateNotification()
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in self?.dismissUpdateNotification() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { [weak self] in
            self?.hasPendingReminder = false
            self?.dismissUpdateNotification()
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        // Store synchronously: the application may terminate immediately afterwards.
        UserDefaults.standard.set(["build": item.versionString, "version": item.displayVersionString],
                                  forKey: "pendingUpdateInstallation")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.recordUpdateAbort(error)
        }
    }

    func recordUpdateAbort(_ error: Error) {
        let error = error as NSError
        // Sparkle also reports a successful check with no update through its abort callback.
        if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
            let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
            recordNoUpdate(latestVersion: item?.displayVersionString ?? latestVersion)
            return
        }
        lastCheckFailed = true
        updateStatus = "Update could not finish: \(error.localizedDescription) Choose Check Now to retry."
    }

    private func confirmPreviousInstallation() {
        guard let pending = UserDefaults.standard.dictionary(forKey: "pendingUpdateInstallation"),
              let build = pending["build"] as? String, let version = pending["version"] as? String else { return }
        if currentBuild.compare(build, options: .numeric) != .orderedAscending {
            updateStatus = "Update installed. You’re running \(currentVersion) (build \(currentBuild))."
            UserDefaults.standard.removeObject(forKey: "pendingUpdateInstallation")
        } else {
            lastCheckFailed = true
            updateStatus = "The update to \(version) did not finish. You’re still running \(currentVersion). Choose Check Now to retry."
        }
    }

    var canShowUpdate: Bool { canCheckForUpdates || hasPendingReminder }
}

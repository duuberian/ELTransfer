import AppKit
import Combine
import CoreGraphics
import Foundation
import Network
import SwiftUI

struct PointerPacket: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var active: Bool
    // Optional so packets from older builds still decode.
    var color: CursorColor?
    var shape: CursorShape?
}

/// The two logo strokes, fitted without the tile, as a template image.
let menuBarArtwork: NSImage = {
    let scale: CGFloat = 0.026
    let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { _ in
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
        let path = NSBezierPath()
        path.move(to: p(356, 318))
        path.curve(to: p(194, 460), controlPoint1: p(296, 382), controlPoint2: p(242, 426))
        path.curve(to: p(512, 460), controlPoint1: p(290, 460), controlPoint2: p(400, 460))
        path.curve(to: p(830, 460), controlPoint1: p(624, 460), controlPoint2: p(734, 460))
        path.curve(to: p(668, 318), controlPoint1: p(782, 426), controlPoint2: p(728, 382))
        path.move(to: p(356, 706))
        path.curve(to: p(194, 564), controlPoint1: p(296, 642), controlPoint2: p(242, 598))
        path.curve(to: p(512, 564), controlPoint1: p(290, 564), controlPoint2: p(400, 564))
        path.curve(to: p(830, 564), controlPoint1: p(624, 564), controlPoint2: p(734, 564))
        path.curve(to: p(668, 706), controlPoint1: p(782, 598), controlPoint2: p(728, 642))
        path.transform(using: AffineTransform(translationByX: 11 - 512 * scale, byY: 11 - 512 * scale))
        path.lineWidth = 70 * scale
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()
        return true
    }
    image.isTemplate = true
    return image
}()

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var sender: Sender?
    var receiver: Receiver?
    private var isConfigured = false
    private let status = MenuStatus()
    private lazy var settingsWindow = SettingsWindowController(status: status)
    private lazy var menuPanel = MenuPanelController(status: status) { [weak self] in self?.openSettings() }
    private var statusTimer: Timer?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = menuBarArtwork
        statusItem.button?.toolTip = "ELTransfer"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMenu)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do {
                // The fresh process owns setup after recovery.
                if try await AccessibilityRecovery.recoverAfterUpdate() { return }
            } catch {
                print("ELTransfer: update permission recovery failed - \(error.localizedDescription)")
            }
            finishLaunching()
        }
    }

    @MainActor private func finishLaunching() {
        requestSystemPermissions()
        settingsWindow.onVisibilityChange = { [weak self] _ in self?.updateStatusTimer() }
        observeUpdates()
        AppUpdater.shared.start()
        // Drop the menu down on launch so it is clear ELTransfer lives in the menu bar.
        // Wait a beat for the status item to be placed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showMenu() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight, Dock) points back at the menu bar.
        showMenu()
        return false
    }

    @MainActor private func observeUpdates() {
        let updater = AppUpdater.shared
        updater.$updateNotification
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                guard version != nil, updater.availableVersion != nil else { return }
                self?.showMenu()
            }
            .store(in: &cancellables)
        // The update row changes the menu's height; resize if it is already open.
        updater.$availableVersion
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, menuPanel.isVisible else { return }
                DispatchQueue.main.async { self.showMenu() }
            }
            .store(in: &cancellables)
    }

    private func requestSystemPermissions() {
        statusItem.button?.title = "⚠️"

        // Ask Accessibility first. This opens System Settings if access is not already granted.
        let accessibilityOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(accessibilityOptions as CFDictionary)

        // Ask for Input Monitoring / global event listening.
        let eventListeningAllowed = CGRequestListenEventAccess()

        status.accessibilityGranted = accessibilityTrusted
        status.inputMonitoringGranted = eventListeningAllowed
        updatePermissionBadge()
        print("ELTransfer: permissions - accessibility=\(accessibilityTrusted), inputMonitoring=\(eventListeningAllowed)")
        print("ELTransfer: if macOS did not prompt, enable ELTransfer in System Settings > Privacy & Security > Accessibility and Input Monitoring.")

        // Services start immediately; they become fully useful once the user grants the prompts.
        configureServices()
        watchPermissions()
    }

    private func updatePermissionBadge() {
        statusItem.button?.title = status.permissionsGranted ? "↔" : "⚠️"
    }

    /// Grants made in System Settings arrive while the app runs. Poll both permissions,
    /// and when one is newly granted reinstall the event monitors, which macOS does not
    /// start delivering to monitors added before access was allowed.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hadAccessibility = status.accessibilityGranted
            let hadInputMonitoring = status.inputMonitoringGranted
            refreshStatus()
            let gained = (!hadAccessibility && status.accessibilityGranted)
                || (!hadInputMonitoring && status.inputMonitoringGranted)
            if gained {
                print("ELTransfer: permissions - accessibility=\(status.accessibilityGranted), inputMonitoring=\(status.inputMonitoringGranted)")
                sender?.reinstallMonitors()
                receiver?.reinstallMonitor()
            }
            updatePermissionBadge()
        }
    }

    private func configureServices() {
        guard !isConfigured else { return }
        sender = Sender()
        receiver = Receiver()
        isConfigured = true
    }

    @objc private func toggleMenu() {
        if menuPanel.isVisible {
            menuPanel.hide()
            updateStatusTimer()
            return
        }
        showMenu()
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        refreshStatus()
        menuPanel.show(below: button)
        updateStatusTimer()
    }

    private func openSettings() {
        menuPanel.hide()
        refreshStatus()
        settingsWindow.show()
    }

    /// Keeps the menu's status tile and the settings' permission rows live while either is open.
    private func updateStatusTimer() {
        guard menuPanel.isVisible || settingsWindow.isVisible else {
            statusTimer?.invalidate()
            statusTimer = nil
            return
        }
        guard statusTimer == nil else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Closing the window or dismissing the menu by an outside click stops the timer here.
            guard menuPanel.isVisible || settingsWindow.isVisible else {
                statusTimer?.invalidate()
                statusTimer = nil
                return
            }
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status.accessibilityGranted = AXIsProcessTrusted()
        status.inputMonitoringGranted = InputMonitoring.isGranted
        status.sending = sender?.isSending ?? false
        status.receiving = receiver?.isReceiving ?? false
    }
}

final class Sender {
    private var connection: NWConnection?
    private var mouseMonitor: Any?
    private var flagMonitor: Any?
    private(set) var isSending = false
    private let host = NWEndpoint.Host("ELTransfer.local")
    private let port: NWEndpoint.Port = 47000
    private var lastPoint = CGPoint.zero

    init() {
        connect()
        installMonitors()
        // Try to catch initial state too.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.handleCursor()
        }
    }

    func reinstallMonitors() {
        [mouseMonitor, flagMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        installMonitors()
    }

    private func connect() {
        connection = NWConnection(host: host, port: port, using: .udp)
        connection?.stateUpdateHandler = { state in
            print("Sender network: \(state)")
        }
        connection?.start(queue: .global())
    }

    private func installMonitors() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            self?.handleCursor()
        }
        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self?.handleCursor(force: true) }
        }
    }

    private func handleCursor(force: Bool = false) {
        guard let point = CGEvent(source: nil)?.location else { return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.frame
        let margin = CGFloat(24)
        let left = point.x <= frame.minX + margin
        let right = point.x >= frame.maxX - margin
        let top = point.y >= frame.maxY - margin
        let bottom = point.y <= frame.minY + margin
        let atEdge = left || right || top || bottom

        if atEdge && NSEvent.modifierFlags.contains(.command) {
            isSending = true
            lastPoint = point
            // Normalized position captures macOS cursor acceleration and speed,
            // then remaps it proportionally on the receiving display.
            let nx = min(max((point.x - frame.minX) / frame.width, 0), 1)
            let ny = min(max((point.y - frame.minY) / frame.height, 0), 1)
            send(packet: PointerPacket(x: nx, y: ny, width: frame.width, height: frame.height, active: true))
        } else if isSending {
            isSending = false
            let nx = min(max((point.x - frame.minX) / frame.width, 0), 1)
            let ny = min(max((point.y - frame.minY) / frame.height, 0), 1)
            send(packet: PointerPacket(x: nx, y: ny, width: frame.width, height: frame.height, active: false))
        }
    }

    private func send(packet: PointerPacket) {
        var packet = packet
        packet.color = CursorSettings.shared.color
        packet.shape = CursorSettings.shared.shape
        guard let data = try? JSONEncoder().encode(packet), let connection else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

final class Receiver {
    private(set) var isReceiving = false
    private var overlay: OverlayWindow?
    private var listener: NWListener?
    private var flagMonitor: Any?
    private var lastPacket = PointerPacket(x: 0.5, y: 0.5, width: 1, height: 1, active: false)
    private var lastUpdate = Date.distantPast
    private var staleCheck: DispatchWorkItem?

    init() {
        installListener()
        installMonitor()
    }

    func reinstallMonitor() {
        if let flagMonitor { NSEvent.removeMonitor(flagMonitor) }
        installMonitor()
    }

    private func installMonitor() {
        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] _ in
            self?.refreshConsent()
        }
    }

    private func refreshConsent() {
        // User consent gesture: receiver also holds Command.
        isReceiving = NSEvent.modifierFlags.contains(.command)
        updateOverlay()
    }

    private func installListener() {
        do {
            let parameters = NWParameters.udp
            listener = try NWListener(using: parameters, on: 47000)
            listener?.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receiveMessage { [weak self] data, _, _, _ in
                    self?.process(data: data)
                    connection.cancel()
                }
            }
            listener?.start(queue: .global())
        } catch {
            print("Receiver listener failed: \(error)")
        }
    }

    private func process(data: Data?) {
        guard let data, let packet = try? JSONDecoder().decode(PointerPacket.self, from: data) else { return }
        DispatchQueue.main.async {
            self.lastPacket = packet
            self.lastUpdate = Date()
            self.updateOverlay()
            // Re-check once the packet goes stale so the pointer fades if the stream stops.
            self.staleCheck?.cancel()
            let check = DispatchWorkItem { [weak self] in self?.updateOverlay() }
            self.staleCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
        }
    }

    private func updateOverlay() {
        let active = isReceiving && lastPacket.active && Date().timeIntervalSince(lastUpdate) < 0.45
        if overlay == nil {
            guard active else { return }
            overlay = OverlayWindow()
        }
        overlay?.show(packet: lastPacket, active: active)
    }
}

/// Pointer state rendered by `PointerView`. Packets mutate this and SwiftUI animates between
/// values, so the overlay window itself never moves per packet.
final class PointerOverlayModel: ObservableObject {
    /// Shape centre in the overlay's top-left-origin coordinates.
    @Published var point = CGPoint.zero
    @Published var active = false
    @Published var color = CursorSettings.shared.color
    @Published var shape = CursorSettings.shared.shape
    /// Set for the update that places a pointer reappearing after its fade-out, so it
    /// settles in place instead of gliding over from where it vanished.
    @Published var snap = true
}

enum OverlayWindowTiming {
    static let fadeOut = 0.28
}

/// A click-through, screen-sized overlay that hosts the remote pointer.
final class OverlayWindow: NSWindow {
    private let model = PointerOverlayModel()
    private var target: (packet: PointerPacket, active: Bool)?
    private var applyScheduled = false
    private var inactiveSince = Date.distantPast
    private var orderOutWork: DispatchWorkItem?

    init() {
        super.init(contentRect: NSScreen.main?.frame ?? .zero,
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PointerView(model: model))
        host.sizingOptions = []
        contentView = host
    }

    func show(packet: PointerPacket, active: Bool) {
        target = (packet, active)
        if active && !isVisible {
            // Put the faded-out view on screen first so the entrance animates from it.
            orderFrontRegardless()
            guard !applyScheduled else { return }
            applyScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.applyScheduled = false
                self?.applyTarget()
            }
        } else if !applyScheduled {
            applyTarget()
        }
    }

    private func applyTarget() {
        guard let (packet, active) = target, let screen = NSScreen.main else { return }
        let wasActive = model.active
        guard active else {
            guard wasActive else { return }
            // Keep the last position and let the view fade; order out once it is invisible.
            model.active = false
            inactiveSince = Date()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !model.active else { return }
                orderOut(nil)
            }
            orderOutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + OverlayWindowTiming.fadeOut + 0.05, execute: work)
            return
        }

        orderOutWork?.cancel()
        orderOutWork = nil
        let frame = screen.frame
        let screenChanged = self.frame != frame
        if screenChanged { setFrame(frame, display: false) }
        if !isVisible { orderFrontRegardless() }

        let point = CGPoint(x: packet.x * frame.width, y: (1 - packet.y) * frame.height)
        let reappearing = !wasActive && Date().timeIntervalSince(inactiveSince) > OverlayWindowTiming.fadeOut
        let snap = screenChanged || reappearing
        if model.snap != snap { model.snap = snap }
        if model.point != point { model.point = point }
        let color = packet.color ?? CursorSettings.shared.color
        let shape = packet.shape ?? CursorSettings.shared.shape
        if model.color != color { model.color = color }
        if model.shape != shape { model.shape = shape }
        if !wasActive { model.active = true }
    }
}

struct PointerView: View {
    @ObservedObject var model: PointerOverlayModel
    private let glyphSize: CGFloat = 38

    var body: some View {
        let active = model.active
        // Scaling around the centre keeps the transmitted point fixed.
        let origin = CGPoint(x: model.point.x - glyphSize / 2, y: model.point.y - glyphSize / 2)

        CursorGlyph(color: model.color, shape: model.shape, lineWidth: 2.5)
            .frame(width: glyphSize, height: glyphSize)
            .background(
                Circle()
                    .fill(model.color.fill)
                    .frame(width: glyphSize * 1.3, height: glyphSize * 1.3)
                    .blur(radius: 10)
                    .opacity(active ? 0.55 : 0)
            )
            .animation(.easeOut(duration: 0.15), value: model.color)
            .saturation(active ? 1 : 0.2)
            .shadow(color: .black.opacity(active ? 0.28 : 0.08), radius: active ? 5 : 1.5, y: active ? 2.5 : 1)
            .scaleEffect(active ? 1 : 0.78, anchor: .center)
            .opacity(active ? 1 : 0)
            .animation(active ? .spring(response: 0.32, dampingFraction: 0.82)
                              : .easeOut(duration: OverlayWindowTiming.fadeOut), value: active)
            .offset(x: origin.x, y: origin.y)
            .animation(model.snap ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.86), value: model.point)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

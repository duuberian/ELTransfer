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
    var senderID: String?
    var senderName: String?
}

/// Identifies this running copy, so a Mac never discovers or draws its own pointer.
enum LocalPeer {
    static let id = UUID().uuidString
    static let name = Host.current().localizedName ?? "A Mac"
    /// Unique per launch; the browser skips the service carrying this name.
    static let serviceName = "\(name.prefix(40)) (\(id.prefix(8)))"
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
    private var isOpen = false
    private let status = MenuStatus()
    private lazy var settingsWindow = SettingsWindowController(status: status)
    private lazy var menuPanel = MenuPanelController(status: status) { [weak self] in self?.openSettings() }
    private var statusTimer: Timer?
    private var permissionTimer: Timer?
    private var permissionsWereMissing = false
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
        settingsWindow.onVisibilityChange = { [weak self] _ in self?.updateStatusTimer() }
        observeUpdates()
        AppUpdater.shared.start()
        watchPermissions()
        if requestSystemPermissions() {
            openApp()
        } else {
            // Permissions come first: event monitors only work in a process started after
            // access was granted, so the app opens once both are allowed and it relaunches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPermissions() }
        }
    }

    private func openApp() {
        guard !isOpen else { return }
        isOpen = true
        configureServices()
        // Drop the menu down on launch so it is clear ELTransfer lives in the menu bar.
        // Wait a beat for the status item to be placed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showMenu() }
    }

    private func showPermissions() {
        menuPanel.hide()
        refreshStatus()
        settingsWindow.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening the app again (Finder, Spotlight, Dock) points back at the menu bar,
        // or at the permissions until they are granted.
        if isOpen { showMenu() } else { showPermissions() }
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

    /// Returns whether both permissions are already granted.
    private func requestSystemPermissions() -> Bool {
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
        permissionsWereMissing = !status.permissionsGranted
        return status.permissionsGranted
    }

    private func updatePermissionBadge() {
        statusItem.button?.title = status.permissionsGranted ? "↔" : "⚠️"
    }

    /// Grants made in System Settings arrive while the app runs. Poll both permissions,
    /// and once both are granted after one was missing, relaunch: Input Monitoring only
    /// reaches a process started after it was allowed.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            refreshStatus()
            updatePermissionBadge()
            // Tracked apart from status, which the menu and settings also refresh.
            guard status.permissionsGranted else { permissionsWereMissing = true; return }
            guard permissionsWereMissing else { return }
            permissionsWereMissing = false
            print("ELTransfer: permissions granted, relaunching")
            Task { @MainActor in
                do {
                    try await AccessibilityRecovery.restart()
                } catch {
                    // Development builds cannot relaunch; start listening in place.
                    self.sender?.reinstallMonitors()
                    self.receiver?.reinstallMonitor()
                    self.settingsWindow.close()
                    self.openApp()
                }
            }
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
    private var connections: [NWConnection] = []
    private var browser: NWBrowser?
    private var mouseMonitor: Any?
    private var flagMonitor: Any?
    private(set) var isSending = false
    private var lastPoint = CGPoint.zero

    init() {
        startDiscovery()
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

    /// Finds the receiver on the local network instead of assuming its hostname.
    private func startDiscovery() {
        browser = NWBrowser(for: .bonjour(type: "_eltransfer._udp", domain: nil), using: .udp)
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            // Connections are kept alive; each result is a nearby receiver instance.
            let endpoints = Set(results.map(\.endpoint).filter { endpoint in
                if case .service(let name, _, _, _) = endpoint { return name != LocalPeer.serviceName }
                return true
            })
            let stale = connections.filter { !endpoints.contains($0.endpoint) }
            stale.forEach { $0.cancel() }
            connections.removeAll { !endpoints.contains($0.endpoint) }
            for endpoint in endpoints where !connections.contains(where: { $0.endpoint == endpoint }) {
                let connection = NWConnection(to: endpoint, using: .udp)
                connection.stateUpdateHandler = { state in
                    if case .failed(let error) = state { print("Sender network failed: \(error)") }
                }
                connection.start(queue: .main)
                connections.append(connection)
            }
        }
        browser?.stateUpdateHandler = { state in
            if case .failed(let error) = state { print("Sender discovery failed: \(error)") }
            if case .waiting(let error) = state { print("Sender discovery waiting: \(error)") }
        }
        browser?.start(queue: .main)
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
        // Cocoa coordinates (bottom-left origin) to match NSScreen frames; the receiver
        // flips y back for its top-left overlay. CGEvent's top-left point inverted y.
        let point = NSEvent.mouseLocation
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
        packet.senderID = LocalPeer.id
        packet.senderName = LocalPeer.name
        guard let data = try? JSONEncoder().encode(packet) else { return }
        for connection in connections where connection.state == .ready {
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
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
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                self?.receive(on: connection)
            }
            listener?.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("Receiver listener failed: \(error)") }
            }
            listener?.service = NWListener.Service(name: LocalPeer.serviceName, type: "_eltransfer._udp")
            listener?.start(queue: .global())
        } catch {
            print("Receiver listener failed: \(error)")
        }
    }

    /// A UDP connection carries every datagram from one sender; keep reading until it ends.
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            self?.process(data: data)
            if error == nil { self?.receive(on: connection) } else { connection.cancel() }
        }
    }

    private func process(data: Data?) {
        guard let data, let packet = try? JSONDecoder().decode(PointerPacket.self, from: data),
              packet.senderID != LocalPeer.id else { return }
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
        let incoming = lastPacket.active && Date().timeIntervalSince(lastUpdate) < 0.45
        let active = isReceiving && incoming
        // A Mac is pushing its pointer but this one has not held ⌘ yet: ask.
        let request = incoming && !isReceiving ? (lastPacket.senderName ?? "A Mac") : nil
        if overlay == nil {
            guard active || request != nil else { return }
            overlay = OverlayWindow()
        }
        overlay?.show(packet: lastPacket, active: active, request: request)
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
    /// Name of a Mac waiting for this one to hold ⌘ and accept its pointer.
    @Published var request: String?
    let swing = PointerSwing()
}

/// Lets the pointer hang from its tip like a pendulum: moving sideways fast leaves its
/// tail behind, and it swings back to rest once the pointer slows. The angle is stepped
/// every display frame from a smoothed velocity, so irregular packet timing never shows.
final class PointerSwing {
    /// Tilt for a very fast sideways move, in degrees.
    private let maxAngle = 30.0
    /// Speed, in points per second, before the tail starts to trail.
    private let deadZone = 180.0
    /// Speed past the dead zone that gives about three quarters of the maximum tilt.
    private let referenceSpeed = 1600.0
    /// Natural swing frequency and damping; slightly underdamped for one soft sway back.
    private let omega = 2 * Double.pi * 2.1
    private let damping = 0.5

    private var lastPoint: CGPoint?
    private var lastPacketTime = 0.0
    private var packetVelocity = 0.0
    private var velocity = 0.0
    private var angle = 0.0
    private var angularVelocity = 0.0
    private var lastStep: Double?

    func record(_ point: CGPoint, snap: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        if snap { reset() }
        if let lastPoint, !snap {
            let dt = now - lastPacketTime
            // A long gap is a pause, not a slow move.
            packetVelocity = dt < 0.25 ? Double(point.x - lastPoint.x) / max(dt, 1.0 / 120) : 0
        }
        lastPoint = point
        lastPacketTime = now
    }

    func reset() {
        lastPoint = nil
        packetVelocity = 0
        velocity = 0
        angle = 0
        angularVelocity = 0
        lastStep = nil
    }

    /// Advances to `time` and returns the tilt in degrees; positive is clockwise.
    func angle(at time: Double) -> Double {
        let elapsed = min(time - (lastStep ?? time), 0.1)
        lastStep = time
        // No new packet means the sender's pointer has stopped.
        let measured = time - lastPacketTime > 0.06 ? 0 : packetVelocity
        var remaining = elapsed
        while remaining > 0 {
            let dt = min(remaining, 1.0 / 240)
            remaining -= dt
            velocity += (measured - velocity) * (1 - exp(-dt / 0.07))
            let speed = max(abs(velocity) - deadZone, 0)
            let target = maxAngle * tanh(speed / referenceSpeed) * (velocity < 0 ? -1 : 1)
            angularVelocity += (omega * omega * (target - angle) - 2 * damping * omega * angularVelocity) * dt
            angle += angularVelocity * dt
        }
        return angle
    }
}

enum OverlayWindowTiming {
    static let fadeOut = 0.28
}

/// A click-through, screen-sized overlay that hosts the remote pointer.
final class OverlayWindow: NSWindow {
    private let model = PointerOverlayModel()
    private var target: (packet: PointerPacket, active: Bool, request: String?)?
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

    func show(packet: PointerPacket, active: Bool, request: String?) {
        target = (packet, active, request)
        if (active || request != nil) && !isVisible {
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
        guard let (packet, active, request) = target, let screen = NSScreen.main else { return }
        let wasActive = model.active
        if model.request != request {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.request = request }
        }
        if request != nil {
            orderOutWork?.cancel()
            orderOutWork = nil
            if frame != screen.frame { setFrame(screen.frame, display: false) }
            if !isVisible { orderFrontRegardless() }
        }
        guard active else {
            if !wasActive {
                if request == nil { scheduleOrderOut() }
                return
            }
            // Keep the last position and let the view fade; order out once it is invisible.
            model.active = false
            inactiveSince = Date()
            if request == nil { scheduleOrderOut() }
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
        model.swing.record(point, snap: snap)
        if model.point != point { model.point = point }
        let color = packet.color ?? CursorSettings.shared.color
        let shape = packet.shape ?? CursorSettings.shared.shape
        if model.color != color { model.color = color }
        if model.shape != shape { model.shape = shape }
        if !wasActive { model.active = true }
    }

    /// Orders the window out once the pointer and any request have faded.
    private func scheduleOrderOut() {
        guard isVisible, orderOutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            orderOutWork = nil
            guard !model.active, model.request == nil else { return }
            orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayWindowTiming.fadeOut + 0.05, execute: work)
    }
}

/// Asks the person at this Mac to hold ⌘ to let another Mac's pointer in.
struct PointerRequestBanner: View {
    let name: String
    let color: CursorColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color.stroke)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) wants to share its pointer")
                    .font(.system(size: 13, weight: .semibold))
                Text("Hold ⌘ Command to let it in")
                    .font(.system(size: 12))
                    .foregroundStyle(ELStyle.muted)
            }
        }
        .foregroundStyle(ELStyle.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(ELStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(ELStyle.line))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

struct PointerView: View {
    @ObservedObject var model: PointerOverlayModel
    private let glyphSize: CGFloat = 38
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        let active = model.active
        let pointer = model.shape.isPointer
        let size = pointer ? CGSize(width: glyphSize * ArrowShape.aspect, height: glyphSize)
                           : CGSize(width: glyphSize, height: glyphSize)
        // The pointer's tip, or the circle's centre, sits on the transmitted point,
        // and scaling around it keeps that point fixed.
        let anchor: UnitPoint = pointer ? .topLeading : .center
        let origin = pointer
            ? CGPoint(x: model.point.x - lineWidth / 2, y: model.point.y - lineWidth / 2)
            : CGPoint(x: model.point.x - glyphSize / 2, y: model.point.y - glyphSize / 2)

        // Swing around the tip, stepped each frame while the pointer is shown.
        let tip = UnitPoint(x: lineWidth / 2 / size.width, y: lineWidth / 2 / size.height)
        TimelineView(.animation(paused: !pointer || !active)) { context in
            CursorGlyph(color: model.color, shape: model.shape, lineWidth: lineWidth)
                .rotationEffect(.degrees(pointer ? model.swing.angle(at: context.date.timeIntervalSinceReferenceDate) : 0),
                                anchor: tip)
        }
            .frame(width: size.width, height: size.height)
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
            .scaleEffect(active ? 1 : 0.78, anchor: anchor)
            .opacity(active ? 1 : 0)
            .animation(active ? .spring(response: 0.32, dampingFraction: 0.82)
                              : .easeOut(duration: OverlayWindowTiming.fadeOut), value: active)
            .offset(x: origin.x, y: origin.y)
            .animation(model.snap ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.86), value: model.point)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .top) {
                if let request = model.request {
                    PointerRequestBanner(name: request, color: model.color)
                        .padding(.top, 48)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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

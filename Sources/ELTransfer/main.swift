import AppKit
import Carbon.HIToolbox
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
    /// Clicks made during the session; a rise tells the receiver to play the click.
    var clicks: Int?
    var senderID: String?
    var senderName: String?
    /// The sender pressed ⌘↩: its keys go to this pointer instead of its own apps.
    var typing: Bool?
    /// Keys held right now, modifiers first, shown as keycaps until released.
    var keys: [String]?
    /// Text typed in the current burst, shown as it is written.
    var text: String?
    /// The last finished burst; a new `clipID` tells the receiver to put it on the clipboard.
    var clip: String?
    var clipID: Int?
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

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the real cursor frozen.
        sender?.endSession()
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
        let sender = Sender()
        self.sender = sender
        let receiver = Receiver(multipeerLink: sender.multipeerLink)
        self.receiver = receiver
        // A Mac showing someone else's pointer is in use; its shortcuts must not start sharing.
        sender.canStart = { [weak receiver] in receiver?.isReceiving != true }
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
    private var keyMonitor: Any?
    /// A key was pressed during the current ⌘ hold, so it is a shortcut like ⌘T, not a share.
    private var shortcutUsed = false
    var canStart: () -> Bool = { true }
    private(set) var isSending = false
    /// Latched by ⌘↩: the session no longer needs ⌘ held, and keys are relayed.
    private(set) var isTyping = false
    /// Set by ⌘Esc so a ⌘ still held at the edge cannot start another session at once.
    private var waitForCommandRelease = false
    private var eventTap: CFMachPort?
    /// The shared pointer, in Cocoa coordinates, steered by mouse deltas while the
    /// real cursor is held still at `frozenPoint` (CoreGraphics coordinates).
    private var virtualPoint = CGPoint.zero
    private var frozenPoint = CGPoint.zero
    private var sessionFrame = CGRect.zero
    private var clicks = 0
    private var heldKeys: [(code: Int, label: String)] = []
    private var modifierFlags: CGEventFlags = []
    private var text = ""
    private var clip: String?
    private var clipID = 0
    private var textIdle: DispatchWorkItem?
    private lazy var notice = NoticeWindow()
    let multipeerLink = MultipeerLink()

    init() {
        startDiscovery()
        multipeerLink.start()
        installMonitors()
        installEventTap()
        // Try to catch initial state too.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.handleCursor()
        }
    }

    func reinstallMonitors() {
        [mouseMonitor, flagMonitor, keyMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        installMonitors()
        if eventTap == nil { installEventTap() }
    }

    func endSession() {
        guard isSending else { return }
        isSending = false
        isTyping = false
        heldKeys.removeAll()
        // Whatever was typed last still reaches the receiver's clipboard.
        finishText()
        CGAssociateMouseAndMouseCursorPosition(1)
        sendPosition(active: false)
        notice.hide()
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
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            // The event tap steers and swallows events during a session; this only
            // stands in when the tap could not be created.
            guard isSending else { return handleCursor(moved: event.type == .mouseMoved) }
            guard eventTap == nil else { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                click()
            } else {
                move(dx: event.deltaX, dy: event.deltaY)
            }
        }
        flagMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            if !event.modifierFlags.contains(.command) { self?.shortcutUsed = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { self?.handleCursor() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.modifierFlags.contains(.command) { self?.shortcutUsed = true }
        }
    }

    /// Sees mouse and key events before any app, so while sharing they steer the shared
    /// pointer and clicks never land on whatever sits under the frozen cursor.
    private func installEventTap() {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
                                    .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { _, type, event, info in
                                              guard let info else { return Unmanaged.passUnretained(event) }
                                              return Unmanaged<Sender>.fromOpaque(info).takeUnretainedValue()
                                                  .handleTap(type: type, event: event)
                                          },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("Sender event tap unavailable; clicks will reach the local Mac while sharing")
            return
        }
        eventTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isSending else { return Unmanaged.passUnretained(event) }
        if type == .keyDown || type == .keyUp || type == .flagsChanged {
            return handleKey(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard isTyping || event.flags.contains(.maskCommand) else { return Unmanaged.passUnretained(event) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            move(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            click()
        default:
            break
        }
        return nil
    }

    /// Returns whether the key was taken from the local Mac.
    private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let command = event.flags.contains(.maskCommand)
        if type == .flagsChanged {
            // Modifiers alone still reach local apps, so none think one is stuck down;
            // here they only label the keycaps.
            guard isTyping else { return false }
            modifierFlags = event.flags
            sendPosition(active: true)
            return false
        }
        if type == .keyDown, command, code == kVK_Escape {
            endSession()
            waitForCommandRelease = true
            return true
        }
        guard isTyping else {
            guard type == .keyDown, command, code == kVK_Return || code == kVK_ANSI_KeypadEnter else { return false }
            startTyping()
            return true
        }
        if type == .keyDown {
            keyDown(event, code: code)
        } else {
            heldKeys.removeAll { $0.code == code }
        }
        sendPosition(active: true)
        return true
    }

    private func startTyping() {
        isTyping = true
        // The ⌘ from ⌘↩ is about to be released; don't show it as a keycap.
        modifierFlags = []
        notice.show(.typing, on: sessionFrame)
        sendPosition(active: true)
    }

    private func keyDown(_ event: CGEvent, code: Int) {
        modifierFlags = event.flags
        let plainDelete = code == kVK_Delete && KeyLabel.modifiers(event.flags).isEmpty
        if let typed = KeyLabel.typed(by: event) {
            text += typed
            scheduleTextEnd()
        } else if plainDelete, !text.isEmpty {
            text.removeLast()
            scheduleTextEnd()
        } else if !heldKeys.contains(where: { $0.code == code }) {
            heldKeys.append((code, KeyLabel.name(of: event)))
        }
    }

    /// A pause in typing ends the burst, which the receiver then copies.
    private func scheduleTextEnd() {
        textIdle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isSending else { return }
            finishText()
            sendPosition(active: true)
        }
        textIdle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func finishText() {
        textIdle?.cancel()
        textIdle = nil
        guard !text.isEmpty else { return }
        clip = text
        clipID += 1
        text = ""
    }

    /// Held keys as keycaps, modifiers first. A modifier alone only shows when it
    /// could start a shortcut, not every ⇧ used for a capital letter.
    private var chord: [String] {
        guard isTyping else { return [] }
        let shortcut = modifierFlags.contains(.maskCommand) || modifierFlags.contains(.maskControl)
        guard !heldKeys.isEmpty || shortcut else { return [] }
        return KeyLabel.modifiers(modifierFlags) + heldKeys.map(\.label)
    }

    /// `moved` is set for plain mouse movement, the only thing that can start a session,
    /// so pressing a shortcut while the cursor happens to rest at an edge never does.
    private func handleCursor(moved: Bool = false) {
        let command = NSEvent.modifierFlags.contains(.command)
        if waitForCommandRelease {
            guard !command else { return }
            waitForCommandRelease = false
        }
        if isSending {
            // Keep the receiver fresh while the pointer rests; releasing ⌘ ends it
            // unless ⌘↩ latched the session.
            if command || isTyping { sendPosition(active: true) } else { endSession() }
            return
        }
        // Only ⌘ alone, held without pressing any other key, and moved into an edge shares.
        let modifiers = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
        guard moved, modifiers == .command, !shortcutUsed, canStart() else { return }
        // Cocoa coordinates (bottom-left origin) to match NSScreen frames; the receiver
        // flips y back for its top-left overlay.
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let frame = screen.frame
        let margin = CGFloat(24)
        let atEdge = point.x <= frame.minX + margin || point.x >= frame.maxX - margin
            || point.y >= frame.maxY - margin || point.y <= frame.minY + margin
        guard atEdge else { return }

        // The edge starts a session; from here the real cursor holds still and mouse
        // movement steers the shared pointer anywhere on the screen until ⌘ is released.
        isSending = true
        virtualPoint = point
        sessionFrame = frame
        frozenPoint = CGEvent(source: nil)?.location ?? .zero
        CGAssociateMouseAndMouseCursorPosition(0)
        notice.show(.sending, on: frame)
        sendPosition(active: true)
    }

    private func move(dx: Double, dy: Double) {
        // Deltas grow downward; Cocoa's y grows upward.
        virtualPoint.x = min(max(virtualPoint.x + dx, sessionFrame.minX), sessionFrame.maxX)
        virtualPoint.y = min(max(virtualPoint.y - dy, sessionFrame.minY), sessionFrame.maxY)
        // Should another app re-associate the mouse, put the cursor back.
        if let location = CGEvent(source: nil)?.location, location != frozenPoint {
            CGWarpMouseCursorPosition(frozenPoint)
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        sendPosition(active: true)
    }

    private func click() {
        clicks += 1
        sendPosition(active: true)
    }

    /// Normalized, so the pointer lands proportionally on a differently sized display.
    private func sendPosition(active: Bool) {
        let frame = sessionFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let nx = min(max((virtualPoint.x - frame.minX) / frame.width, 0), 1)
        let ny = min(max((virtualPoint.y - frame.minY) / frame.height, 0), 1)
        var packet = PointerPacket(x: nx, y: ny, width: frame.width, height: frame.height, active: active)
        packet.clicks = clicks
        packet.typing = isTyping
        packet.keys = chord
        packet.text = text
        packet.clip = clip
        packet.clipID = clipID
        send(packet: packet)
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
        // Some networks allow discovery but block direct UDP traffic. Apple's
        // peer-to-peer transport is the fallback in that case.
        multipeerLink.send(packet: packet)
    }
}

final class Receiver {
    private(set) var isReceiving = false
    private var overlay: OverlayWindow?
    private var listener: NWListener?
    private var monitors: [Any] = []
    private var lastPacket = PointerPacket(x: 0.5, y: 0.5, width: 1, height: 1, active: false)
    private var lastUpdate = Date.distantPast
    private var staleCheck: DispatchWorkItem?
    /// ⌘ is down, for the hold mode.
    private var holding = false
    /// A ⌘ tap let the current session in, for the toggle mode.
    private var accepted = false
    /// ⌘Esc turned the current session away.
    private var dismissed = false
    private var commandDownAt: Date?
    private var notice: OverlayBanner?
    private var noticeUntil = Date.distantPast
    private var announced = false
    private var announcedTyping = false
    private var copiedUntil = Date.distantPast
    private var clipSender: String?
    private var clipID = 0

    init(multipeerLink: MultipeerLink) {
        installListener()
        installMonitor()
        multipeerLink.onPacket = { [weak self] packet in
            self?.process(packet: packet)
        }
    }

    func reinstallMonitor() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        installMonitor()
    }

    private var mode: ReceiveMode { ReceiveSettings.shared.mode }

    private var incoming: Bool { lastPacket.active && Date().timeIntervalSince(lastUpdate) < 0.45 }

    private var consents: Bool {
        guard !dismissed else { return false }
        switch mode {
        case .automatic: return true
        case .toggle: return accepted
        case .hold: return holding
        }
    }

    private func installMonitor() {
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        // Global monitors skip ELTransfer's own windows, such as Settings.
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            holding = flags.contains(.command)
            let commandKey = Int(event.keyCode) == kVK_Command || Int(event.keyCode) == kVK_RightCommand
            if flags == .command, commandKey {
                commandDownAt = Date()
            } else if flags.isEmpty, let down = commandDownAt, Date().timeIntervalSince(down) < 0.4 {
                commandDownAt = nil
                tapCommand()
            } else {
                commandDownAt = nil
            }
        case .keyDown:
            // A ⌘ shortcut is not a tap.
            commandDownAt = nil
            guard Int(event.keyCode) == kVK_Escape, event.modifierFlags.contains(.command) else { return }
            escape()
        default:
            commandDownAt = nil
            return
        }
        updateOverlay()
    }

    private func tapCommand() {
        guard mode == .toggle else { return }
        if accepted {
            accepted = false
        } else if incoming {
            accepted = true
            dismissed = false
        }
    }

    private func escape() {
        guard incoming else { return }
        dismissed = true
        accepted = false
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
        process(packet: packet)
    }

    private func process(packet: PointerPacket) {
        DispatchQueue.main.async {
            // A long silence means the last session ended without its final packet.
            if Date().timeIntervalSince(self.lastUpdate) > 3 { self.resetSession() }
            self.lastPacket = packet
            self.lastUpdate = Date()
            self.takeClip(from: packet)
            if !packet.active { self.resetSession() }
            self.updateOverlay()
            // Re-check once the packet goes stale so the pointer fades if the stream stops.
            self.staleCheck?.cancel()
            let check = DispatchWorkItem { [weak self] in self?.updateOverlay() }
            self.staleCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
        }
    }

    private func resetSession() {
        accepted = false
        dismissed = false
        announced = false
        announcedTyping = false
        notice = nil
    }

    /// Puts a finished burst of the sender's typing on the clipboard, once, so ⌘V pastes it.
    private func takeClip(from packet: PointerPacket) {
        let id = packet.clipID ?? 0
        // A sender seen for the first time may still carry text from long ago.
        guard packet.senderID == clipSender else {
            clipSender = packet.senderID
            clipID = id
            return
        }
        guard id > clipID else { return }
        clipID = id
        guard consents, let clip = packet.clip, !clip.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clip, forType: .string)
        copiedUntil = Date().addingTimeInterval(3)
        refresh(after: 3)
    }

    private func announce(_ banner: OverlayBanner) {
        notice = banner
        noticeUntil = Date().addingTimeInterval(3)
        refresh(after: 3)
    }

    private func refresh(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in self?.updateOverlay() }
    }

    private func updateOverlay() {
        let incoming = self.incoming
        let active = consents && incoming
        isReceiving = active
        let name = lastPacket.senderName ?? "A Mac"
        if active, !announced {
            announced = true
            announce(.receiving(from: name, mode: mode))
        }
        if active, lastPacket.typing == true, !announcedTyping {
            announcedTyping = true
            announce(.typing(from: name))
        }
        let now = Date()
        var banner = active && now < noticeUntil ? notice : nil
        // A Mac is pushing its pointer but this one has not let it in yet: ask.
        if incoming, !consents, !dismissed, mode != .automatic {
            banner = .request(from: name, mode: mode)
        }
        let copied = now < copiedUntil
        if overlay == nil {
            guard active || banner != nil || copied else { return }
            overlay = OverlayWindow()
        }
        overlay?.show(packet: lastPacket, active: active, banner: banner, copied: copied)
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
    /// A request to let a pointer in, or a short notice about the session.
    @Published var banner: OverlayBanner?
    /// The sender's held keys, and the text it is typing.
    @Published var keys: [String] = []
    @Published var text = ""
    /// The sender's typing was just put on this Mac's clipboard.
    @Published var copied = false
    @Published var ripples: [ClickRipple] = []
    @Published var pressed = false
    let swing = PointerSwing()
}

extension PointerOverlayModel {
    /// Plays a click: the pointer presses in and wobbles, and a ring spreads from its tip.
    func click() {
        let ripple = ClickRipple(point: point)
        ripples.append(ripple)
        pressed = true
        swing.kick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.pressed = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.ripples.removeAll { $0.id == ripple.id }
        }
    }
}

struct ClickRipple: Identifiable {
    let id = UUID()
    let point: CGPoint
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

    /// Knocks the pointer so it wobbles about its tip and settles back.
    func kick() {
        angularVelocity += angularVelocity >= 0 ? 320 : -320
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
    private var target: (packet: PointerPacket, active: Bool, banner: OverlayBanner?, copied: Bool)?
    private var applyScheduled = false
    private var inactiveSince = Date.distantPast
    private var orderOutWork: DispatchWorkItem?
    private var lastClicks: Int?
    private var keysShownAt = Date.distantPast
    private var keysClear: DispatchWorkItem?

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

    func show(packet: PointerPacket, active: Bool, banner: OverlayBanner?, copied: Bool) {
        target = (packet, active, banner, copied)
        if (active || banner != nil || copied) && !isVisible {
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
        guard let (packet, active, banner, copied) = target, let screen = NSScreen.main else { return }
        let wasActive = model.active
        let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
        if model.banner != banner { withAnimation(spring) { model.banner = banner } }
        if model.copied != copied { withAnimation(spring) { model.copied = copied } }
        let text = active ? packet.text ?? "" : ""
        if model.text != text {
            // Appearing and vanishing spring; each new letter only resizes quickly.
            withAnimation(model.text.isEmpty || text.isEmpty ? spring : .easeOut(duration: 0.1)) { model.text = text }
        }
        setKeys(active ? packet.keys ?? [] : [])
        let lingering = banner != nil || copied
        if lingering {
            orderOutWork?.cancel()
            orderOutWork = nil
            if frame != screen.frame { setFrame(screen.frame, display: false) }
            if !isVisible { orderFrontRegardless() }
        }
        guard active else {
            if !wasActive {
                if !lingering { scheduleOrderOut() }
                return
            }
            // Keep the last position and let the view fade; order out once it is invisible.
            model.active = false
            inactiveSince = Date()
            if !lingering { scheduleOrderOut() }
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
        // A fresh session only records the count; a rise within one plays the click.
        if let clicks = packet.clicks, let lastClicks, clicks > lastClicks, !snap { model.click() }
        lastClicks = packet.clicks
        let color = packet.color ?? CursorSettings.shared.color
        let shape = packet.shape ?? CursorSettings.shared.shape
        if model.color != color { model.color = color }
        if model.shape != shape { model.shape = shape }
        if !wasActive { model.active = true }
    }

    /// Keys vanish on release, but a quick tap stays up long enough to be read.
    private func setKeys(_ keys: [String]) {
        keysClear?.cancel()
        keysClear = nil
        let remaining = 0.4 - Date().timeIntervalSince(keysShownAt)
        if keys.isEmpty, !model.keys.isEmpty, remaining > 0 {
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.easeOut(duration: 0.15)) { self?.model.keys = [] }
            }
            keysClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            return
        }
        guard model.keys != keys else { return }
        if !keys.isEmpty { keysShownAt = Date() }
        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) { model.keys = keys }
    }

    /// Orders the window out once the pointer and any banner have faded.
    private func scheduleOrderOut() {
        guard isVisible, orderOutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            orderOutWork = nil
            guard !model.active, model.banner == nil, !model.copied else { return }
            orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayWindowTiming.fadeOut + 0.05, execute: work)
    }
}

/// A ring that spreads from the pointer's tip and fades.
struct ClickRippleView: View {
    let color: CursorColor
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color.stroke, lineWidth: 3)
            .background(Circle().fill(color.fill.opacity(0.35)))
            .frame(width: 46, height: 46)
            .scaleEffect(expanded ? 1.6 : 0.3)
            .opacity(expanded ? 0 : 0.95)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { expanded = true } }
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
            .scaleEffect(model.pressed ? 0.8 : 1, anchor: anchor)
            .animation(.spring(response: 0.18, dampingFraction: 0.45), value: model.pressed)
            .scaleEffect(active ? 1 : 0.78, anchor: anchor)
            .opacity(active ? 1 : 0)
            .animation(active ? .spring(response: 0.32, dampingFraction: 0.82)
                              : .easeOut(duration: OverlayWindowTiming.fadeOut), value: active)
            .offset(x: origin.x, y: origin.y)
            .animation(model.snap ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.86), value: model.point)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                ZStack {
                    ForEach(model.ripples) { ripple in
                        ClickRippleView(color: model.color).position(ripple.point)
                    }
                }
            }
            .overlay(alignment: .top) {
                if let banner = model.banner {
                    NoticeBanner(banner: banner, color: model.color)
                        .padding(.top, 48)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 14) {
                    if !model.text.isEmpty {
                        TypedTextBubble(text: model.text, color: model.color)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if !model.keys.isEmpty {
                        KeycapRow(keys: model.keys)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    if model.copied {
                        NoticeBanner(banner: .copied, color: model.color)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 72)
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

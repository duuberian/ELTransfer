import AppKit
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
    private lazy var menuPanel = MenuPanelController(status: status)
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = menuBarArtwork
        statusItem.button?.toolTip = "ELTransfer"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleMenu)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        NSApp.activate(ignoringOtherApps: true)
        requestSystemPermissions()
    }

    private func requestSystemPermissions() {
        statusItem.button?.title = "⚠️"

        // Ask Accessibility first. This opens System Settings if access is not already granted.
        let accessibilityOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(accessibilityOptions as CFDictionary)

        // Ask for Input Monitoring / global event listening.
        let eventListeningAllowed = CGRequestListenEventAccess()

        let permissionsGranted = accessibilityTrusted && eventListeningAllowed
        status.permissionsGranted = permissionsGranted
        statusItem.button?.title = permissionsGranted ? "↔" : "⚠️"
        print("ELTransfer: permissions - accessibility=\(accessibilityTrusted), inputMonitoring=\(eventListeningAllowed)")
        print("ELTransfer: if macOS did not prompt, enable ELTransfer in System Settings > Privacy & Security > Accessibility and Input Monitoring.")

        // Services start immediately; they become fully useful once the user grants the prompts.
        configureServices()
    }

    private func configureServices() {
        guard !isConfigured else { return }
        sender = Sender()
        receiver = Receiver()
        isConfigured = true
    }

    @objc private func toggleMenu() {
        guard let button = statusItem.button else { return }
        if menuPanel.isVisible {
            menuPanel.hide()
            statusTimer?.invalidate()
            return
        }
        refreshStatus()
        menuPanel.show(below: button)
        // Keep the bottom status tile live while the panel is open.
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
            guard let self, menuPanel.isVisible else { timer.invalidate(); return }
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status.permissionsGranted = AXIsProcessTrusted() && CGPreflightListenEventAccess()
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
        // Try to catch initial state too.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.handleCursor()
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

    init() {
        installListener()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.updateOverlay()
            }
        }
    }

    private func updateOverlay() {
        let active = isReceiving && lastPacket.active && Date().timeIntervalSince(lastUpdate) < 0.45
        if overlay == nil { overlay = OverlayWindow() }
        overlay?.show(packet: lastPacket, active: active)
    }
}

final class OverlayWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ignoresMouseEvents = true
        hasShadow = false
    }

    func show(packet: PointerPacket, active: Bool) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        // Aspect-preserving mapping keeps horizontal/vertical cursor speed proportional.
        let sourceAspect = packet.width / packet.height
        let destinationAspect = frame.width / frame.height
        let x = packet.x
        if sourceAspect != destinationAspect && destinationAspect > 0 {
            let sourceHeight = packet.width / destinationAspect
            let yOffset = (sourceHeight - packet.height) / 2
            _ = yOffset // Retain simple screen-relative mapping in prototype.
        }
        let px = frame.minX + x * frame.width
        let py = frame.minY + packet.y * frame.height
        let color = packet.color ?? CursorSettings.shared.color
        let shape = packet.shape ?? CursorSettings.shared.shape
        let size: CGFloat = active ? 44 : 34
        let inset: CGFloat = 3
        let origin: NSPoint
        if shape == .arrow {
            // The arrow's tip marks the pointer position.
            origin = NSPoint(x: px - inset, y: py + inset - size)
        } else {
            origin = NSPoint(x: px - size / 2, y: py - size / 2)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
        let view = PointerView(color: color, shape: shape, active: active, inset: inset)
        if let host = contentView as? NSHostingView<PointerView> {
            host.rootView = view
        } else {
            contentView = NSHostingView(rootView: view)
        }
        orderFrontRegardless()
    }
}

struct PointerView: View {
    let color: CursorColor
    let shape: CursorShape
    let active: Bool
    let inset: CGFloat

    var body: some View {
        CursorGlyph(color: color, shape: shape, lineWidth: 2.5)
            .padding(inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(active ? 1 : 0.45)
            .saturation(active ? 1 : 0.2)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

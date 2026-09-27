import AppKit
import Combine
import SwiftUI

/// While the mouse is over ELTransfer's own windows, the system arrow is hidden and the
/// chosen pointer, swing included, is drawn in its place. The overlay ignores the mouse,
/// and the pointer's tip (or the circle's centre) sits on the hotspot, so clicks land
/// exactly where it points.
final class LocalPointer {
    static let shared = LocalPointer()

    private struct Region {
        weak var window: NSWindow?
        let rect: (NSWindow) -> NSRect
    }

    private var regions: [Region] = []
    private let model = PointerOverlayModel()
    private lazy var overlay = makeOverlay()
    private var timer: Timer?
    private var isInside = false
    private var cancellables: Set<AnyCancellable> = []
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    private init() {
        // Position follows the mouse exactly; only the swing and entrance animate.
        model.snap = true
        CursorSettings.shared.$color.sink { [weak self] in self?.model.color = $0 }.store(in: &cancellables)
        CursorSettings.shared.$shape.sink { [weak self] in self?.model.shape = $0 }.store(in: &cancellables)
    }

    /// Draws the pointer over `window`, limited to `rect` (screen coordinates) when the
    /// window has transparent margins.
    func track(_ window: NSWindow, rect: @escaping (NSWindow) -> NSRect = { $0.frame }) {
        regions.removeAll { $0.window == nil || $0.window === window }
        regions.append(Region(window: window, rect: rect))
        wake()
    }

    /// Call when a tracked window appears so hovering is noticed.
    func wake() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let live = regions.compactMap { region -> (NSWindow, NSRect)? in
            guard let window = region.window, window.isVisible, !window.ignoresMouseEvents else { return nil }
            return (window, region.rect(window))
        }
        let inside = live.contains { window, rect in
            rect.contains(mouse) && !isCovered(window, at: mouse)
        }
        if inside != isInside {
            isInside = inside
            inside ? enter(at: mouse) : exit()
        }
        if inside {
            move(to: mouse)
            // Other views may reset the cursor on the way in; keep the arrow hidden.
            blankCursor.set()
        } else if live.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private var coverCache: (window: Int, time: TimeInterval, covered: Bool)?

    /// Whether another app's window sits above `window` at `mouse`. Asking the window
    /// server is costly, so a result is reused for a moment.
    private func isCovered(_ window: NSWindow, at mouse: NSPoint) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        if let cache = coverCache, cache.window == window.windowNumber, now - cache.time < 0.1 {
            return cache.covered
        }
        let covered = windowsAbove(window).contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) != getpid(),
                  // Screen-saver-level windows are click-through overlays, like ELTransfer's own.
                  (0..<Int(CGWindowLevelForKey(.screenSaverWindow))).contains(info[kCGWindowLayer as String] as? Int ?? 0),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            // Window server bounds are top-left origin on the primary display.
            let flipped = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y)
            return rect.contains(flipped)
        }
        coverCache = (window.windowNumber, now, covered)
        return covered
    }

    private func windowsAbove(_ window: NSWindow) -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .optionOnScreenAboveWindow, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, CGWindowID(window.windowNumber)) as? [[String: Any]] ?? []
    }

    private func enter(at mouse: NSPoint) {
        model.swing.reset()
        model.active = false
        move(to: mouse)
        overlay.orderFrontRegardless()
        NSCursor.hide()
        DispatchQueue.main.async { [weak self] in
            guard let self, isInside else { return }
            model.active = true
        }
    }

    private func exit() {
        // Hand straight back to the system arrow so two pointers never show at once.
        model.active = false
        overlay.orderOut(nil)
        NSCursor.unhide()
        NSCursor.arrow.set()
    }

    private func move(to mouse: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else { return }
        if overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: false) }
        let point = CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
        model.swing.record(point, snap: false)
        if model.point != point { model.point = point }
    }

    private func makeOverlay() -> NSWindow {
        let window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PointerView(model: model))
        host.sizingOptions = []
        window.contentView = host
        return window
    }
}

import AppKit
import Combine
import SwiftUI

/// While the mouse is over ELTransfer's own views, the system arrow becomes the chosen
/// pointer, swing included. It is a real cursor drawn by the window server, so it never
/// lags the mouse, and its hotspot is the pointer's tip (or the circle's centre), so
/// clicks land exactly where it points.
@MainActor
final class LocalPointer {
    static let shared = LocalPointer()

    /// Height of the pointer glyph, in points; the circle uses it as its diameter.
    private let glyphSize: CGFloat = 26
    private let lineWidth: CGFloat = 2
    private let swing = PointerSwing()
    private var hovered: Set<String> = []
    private var timer: Timer?
    private var cursors: [String: NSCursor] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        allowCursorInBackground()
        // Switching apps (⌘-Tab) lets the new front app reset the cursor; take it back.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in self?.apply() }
                .store(in: &cancellables)
        }
        // A new look replaces every cached image.
        CursorSettings.shared.$color.combineLatest(CursorSettings.shared.$shape)
            .dropFirst()
            .sink { [weak self] _, _ in
                self?.cursors.removeAll()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply() } }
            }
            .store(in: &cancellables)
    }

    /// `region` names a hover area; the pointer shows while any area is hovered.
    func hover(_ region: String, inside: Bool) {
        let wasInside = !hovered.isEmpty
        if inside { hovered.insert(region) } else { hovered.remove(region) }
        guard wasInside != !hovered.isEmpty else { return }
        inside ? begin() : end()
    }

    private func begin() {
        swing.reset()
        record()
        apply()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        NSCursor.arrow.set()
    }

    private func tick() {
        // A hovered view that vanished (the menu closing under the mouse) sends no exit.
        let mouse = NSEvent.mouseLocation
        let overOwnWindow = NSApp.windows.contains { window in
            window.isVisible && !window.ignoresMouseEvents && window.level != .screenSaver
                && window.frame.contains(mouse)
        }
        guard overOwnWindow else {
            hovered.removeAll()
            end()
            return
        }
        record()
        apply()
    }

    private func record() {
        let mouse = NSEvent.mouseLocation
        swing.record(CGPoint(x: mouse.x, y: -mouse.y), snap: false)
    }

    /// Sets the cursor for the current swing angle. It is reasserted every frame: hosted
    /// views reset it as the mouse crosses them, and so does whichever app is in front,
    /// which this process cannot observe.
    private func apply() {
        guard !hovered.isEmpty else { return }
        let shape = CursorSettings.shared.shape
        let angle = shape.isPointer ? swing.angle(at: Date.timeIntervalSinceReferenceDate) : 0
        let cursor = cursor(color: CursorSettings.shared.color, shape: shape, degrees: Int(angle.rounded()))
        cursor.set()
    }

    /// macOS normally lets only the frontmost app set the cursor, so the menu (which never
    /// activates ELTransfer) or a window left behind by ⌘-Tab would show the system arrow.
    /// This window-server connection property lifts that. It is private, so it is looked up
    /// at runtime; if it is missing the pointer simply shows only while ELTransfer is active.
    private func allowCursorInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setSymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setSymbol, to: SetProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    private func cursor(color: CursorColor, shape: CursorShape, degrees: Int) -> NSCursor {
        let key = "\(color.rawValue)-\(shape.rawValue)-\(degrees)"
        if let cursor = cursors[key] { return cursor }
        let cursor = makeCursor(color: color, shape: shape, degrees: Double(degrees))
        cursors[key] = cursor
        return cursor
    }

    /// Renders the glyph on a square canvas centred on the hotspot, so it can turn about
    /// the tip without clipping.
    private func makeCursor(color: CursorColor, shape: CursorShape, degrees: Double) -> NSCursor {
        let pointer = shape.isPointer
        let size = pointer ? CGSize(width: glyphSize * ArrowShape.aspect, height: glyphSize)
                           : CGSize(width: glyphSize, height: glyphSize)
        let half = (pointer ? glyphSize * 1.25 : glyphSize / 2) + 4
        let offset = pointer ? CGPoint(x: half - lineWidth / 2, y: half - lineWidth / 2)
                             : CGPoint(x: half - size.width / 2, y: half - size.height / 2)
        let image = NSImage(size: NSSize(width: half * 2, height: half * 2))
        let renderer = ImageRenderer(content: CursorImage(color: color, shape: shape, lineWidth: lineWidth,
                                                          size: size, degrees: degrees, offset: offset, side: half * 2))
        renderer.scale = 2
        if let cgImage = renderer.cgImage {
            image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
            image.representations.first?.size = image.size
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: half, y: half))
    }
}

/// One frame of the cursor: the glyph turned about its tip and placed on the canvas.
private struct CursorImage: View {
    let color: CursorColor
    let shape: CursorShape
    let lineWidth: CGFloat
    let size: CGSize
    let degrees: Double
    let offset: CGPoint
    let side: CGFloat

    var body: some View {
        let tip = UnitPoint(x: lineWidth / 2 / size.width, y: lineWidth / 2 / size.height)
        CursorGlyph(color: color, shape: shape, lineWidth: lineWidth)
            .frame(width: size.width, height: size.height)
            .rotationEffect(.degrees(degrees), anchor: tip)
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
            .offset(x: offset.x, y: offset.y)
            .frame(width: side, height: side, alignment: .topLeading)
    }
}

extension View {
    /// Shows ELTransfer's pointer in place of the arrow while the mouse is over this view.
    func localPointer(_ region: String) -> some View {
        onContinuousHover { phase in
            if case .active = phase {
                LocalPointer.shared.hover(region, inside: true)
            } else {
                LocalPointer.shared.hover(region, inside: false)
            }
        }
    }
}

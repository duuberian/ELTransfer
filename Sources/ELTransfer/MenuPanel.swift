import AppKit
import SwiftUI

/// Live state shown along the bottom of the menu.
final class MenuStatus: ObservableObject {
    @Published var accessibilityGranted = false
    @Published var inputMonitoringGranted = false
    @Published var sending = false
    @Published var receiving = false

    var permissionsGranted: Bool { accessibilityGranted && inputMonitoringGranted }

    var summary: String {
        if !permissionsGranted { return "Needs permissions" }
        if sending { return "Sending pointer" }
        if receiving { return "Receiving pointer" }
        return "Hold ⌘ at an edge"
    }
}

struct MenuView: View {
    @ObservedObject var settings = CursorSettings.shared
    @ObservedObject var status: MenuStatus
    @ObservedObject private var updater = AppUpdater.shared
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CursorGlyph(color: settings.color, shape: settings.shape, lineWidth: 3)
                .frame(width: 84, height: 84)
                .frame(height: 132)
                .padding(.top, 12)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: settings.shape)
                .animation(.easeOut(duration: 0.15), value: settings.color)
                .accessibilityLabel("Cursor preview")

            HStack {
                ForEach(CursorColor.allCases) { color in
                    Button { settings.color = color } label: {
                        Circle().fill(color.fill)
                            .overlay(Circle().strokeBorder(color.stroke, lineWidth: 2.5))
                            .frame(width: 30, height: 30)
                            .padding(4)
                            .overlay(Circle().strokeBorder(ELStyle.ink.opacity(settings.color == color ? 0.35 : 0), lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.rawValue.capitalized)
                    .accessibilityLabel(color.rawValue.capitalized)
                    if color != CursorColor.allCases.last { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 6)

            HStack(spacing: 6) {
                ForEach(CursorShape.allCases) { shape in
                    Button { settings.shape = shape } label: {
                        CursorGlyph(color: settings.color, shape: shape, lineWidth: 2, filled: false)
                            .frame(width: 30, height: 30)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(settings.shape == shape ? ELStyle.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(shape.label)
                    .accessibilityLabel(shape.label)
                }
            }
            .padding(5)
            .background(ELStyle.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 1))

            if let version = updater.availableVersion {
                Button { updater.checkForUpdates() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(settings.color.stroke)
                        Text("Update Available")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(version)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(ELStyle.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .modifier(TileStyle())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!updater.canShowUpdate)
                .help("Review the ELTransfer \(version) update")
                .accessibilityLabel("Update available, ELTransfer \(version). Review update")
            }

            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.sending || status.receiving ? settings.color.stroke : ELStyle.muted)
                    .frame(width: 48, height: 40)
                    .modifier(TileStyle())
                    .help("Sender: hold ⌘ at a screen edge. Receiver: hold ⌘ to allow the incoming pointer.")
                Button(action: openSettings) {
                    Text(status.summary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(status.permissionsGranted ? ELStyle.muted : .orange)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .modifier(TileStyle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",")
                .help("ELTransfer \(updater.currentVersion) — Open Settings")
                .accessibilityLabel("\(status.summary). Open Settings")
                Button(action: quit) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ELStyle.muted)
                        .frame(width: 48, height: 40)
                        .modifier(TileStyle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                .help("Quit ELTransfer")
                .accessibilityLabel("Quit ELTransfer")
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(ELStyle.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 0.7))
        .foregroundStyle(ELStyle.ink)
        .localPointer("menu")
    }
}

private struct TileStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(ELStyle.soft.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 1))
    }
}

private final class MenuPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// Drives the panel's entrance and exit. The window stays ordered in until the exit finishes.
final class MenuPresentation: ObservableObject {
    @Published var isPresented = false
}

/// Wraps the menu with a drawn shadow and the popover-style transition. The window itself is
/// shadowless and oversized by `insets` so the shadow and scale animate with the content.
private struct MenuPanelRoot: View {
    static let insets = EdgeInsets(top: 4, leading: 24, bottom: 36, trailing: 24)
    static let hideDuration = 0.18

    @ObservedObject var presentation: MenuPresentation
    let menu: MenuView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = presentation.isPresented
        let settled = shown || reduceMotion
        menu
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(ELStyle.surface)
            )
            .compositingGroup()
            .scaleEffect(settled ? 1 : 0.94, anchor: .top)
            .offset(y: settled ? 0 : -10)
            .opacity(shown ? 1 : 0)
            .animation(animation(shown: shown), value: shown)
            .padding(Self.insets)
    }

    private func animation(shown: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: shown ? 0.2 : Self.hideDuration) }
        return shown ? .spring(response: 0.38, dampingFraction: 0.82) : .easeOut(duration: Self.hideDuration)
    }
}

/// A non-activating panel under the status item, styled like ELWifi's menu.
final class MenuPanelController {
    private let panel: MenuPanelWindow
    private let presentation = MenuPresentation()
    private var clickMonitors: [Any] = []
    private var orderOutWork: DispatchWorkItem?
    /// Logical open state; the panel can still be on screen while its exit animation runs.
    private(set) var isVisible = false

    init(status: MenuStatus, openSettings: @escaping () -> Void) {
        panel = MenuPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let menu = MenuView(status: status, openSettings: openSettings) { NSApp.terminate(nil) }
        let host = TransparentHostingView(rootView: MenuPanelRoot(presentation: presentation, menu: menu))
        host.setFrameSize(host.fittingSize)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func show(below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        orderOutWork?.cancel()
        orderOutWork = nil
        isVisible = true

        let insets = MenuPanelRoot.insets
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let menuWidth = size.width - insets.leading - insets.trailing
        let screen = window.screen ?? NSScreen.main
        var x = anchor.midX - menuWidth / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - menuWidth - 8)
        }
        let top = anchor.minY - 6 + insets.top
        panel.setFrame(NSRect(x: x - insets.leading, y: top - size.height, width: size.width, height: size.height), display: true)

        let wasOnScreen = panel.isVisible
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        startDismissMonitors(ignoring: button)
        if wasOnScreen {
            // Reopened mid-exit: reverse from the current in-flight state.
            presentation.isPresented = true
        } else {
            // Let the collapsed state reach the screen once so the entrance actually animates.
            DispatchQueue.main.async { [weak self] in
                guard let self, isVisible else { return }
                presentation.isPresented = true
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        panel.ignoresMouseEvents = true
        presentation.isPresented = false
        let work = DispatchWorkItem { [weak self] in
            guard let self, !isVisible else { return }
            panel.orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuPanelRoot.hideDuration + 0.02, execute: work)
    }
    private func startDismissMonitors(ignoring button: NSStatusBarButton) {
        guard clickMonitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.hide()
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self, weak button] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { hide(); return nil } // Escape
                return event
            }
            // The status button toggles the panel itself.
            if event.window === panel || event.window === button?.window { return event }
            hide()
            return event
        }) { clickMonitors.append(local) }
    }
}

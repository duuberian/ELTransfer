import AppKit
import SwiftUI

/// Live state shown along the bottom of the menu.
final class MenuStatus: ObservableObject {
    @Published var permissionsGranted = false
    @Published var sending = false
    @Published var receiving = false

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
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CursorGlyph(color: settings.color, shape: settings.shape, lineWidth: 3)
                .frame(width: settings.shape == .arrow ? 96 : 84, height: settings.shape == .arrow ? 120 : 84)
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
                        CursorGlyph(color: settings.color, shape: shape, lineWidth: 2)
                            .frame(width: shape == .arrow ? 20 : 24, height: shape == .arrow ? 26 : 24)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(settings.shape == shape ? ELStyle.selected : .clear,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(shape.rawValue.capitalized)
                    .accessibilityLabel(shape.rawValue.capitalized)
                }
            }
            .padding(5)
            .background(ELStyle.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 1))

            HStack(spacing: 8) {
                Image(systemName: "command")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(status.sending || status.receiving ? settings.color.stroke : ELStyle.muted)
                    .frame(width: 48, height: 40)
                    .modifier(TileStyle())
                    .help("Sender: hold ⌘ at a screen edge. Receiver: hold ⌘ to allow the incoming pointer.")
                Text(status.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status.permissionsGranted ? ELStyle.muted : .orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .modifier(TileStyle())
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

/// A non-activating panel under the status item, styled like ELWifi's menu.
final class MenuPanelController {
    private let panel: MenuPanelWindow
    private var clickMonitors: [Any] = []

    init(status: MenuStatus) {
        panel = MenuPanelWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = TransparentHostingView(rootView: MenuView(status: status) { NSApp.terminate(nil) })
        host.setFrameSize(host.fittingSize)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    var isVisible: Bool { panel.isVisible }

    func show(below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let screen = window.screen ?? NSScreen.main
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        startDismissMonitors(ignoring: button)
    }

    func hide() {
        panel.orderOut(nil)
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
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

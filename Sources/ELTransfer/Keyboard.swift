import AppKit
import Carbon.HIToolbox
import SwiftUI

/// How this Mac lets another Mac's pointer in.
enum ReceiveMode: String, CaseIterable, Identifiable {
    case automatic, toggle, hold
    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Always"
        case .toggle: "Tap ⌘"
        case .hold: "Hold ⌘"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: "A shared pointer appears as soon as another Mac sends it, so you keep both hands free. Press ⌘Esc to turn one away."
        case .toggle: "Tap ⌘ Command once to let a shared pointer in, and tap it again or press ⌘Esc to stop."
        case .hold: "Hold ⌘ Command for as long as you want to see a shared pointer. ⌘Esc turns one away."
        }
    }
}

/// The receiving side's choices, remembered between launches.
final class ReceiveSettings: ObservableObject {
    static let shared = ReceiveSettings()

    @Published var mode: ReceiveMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "receiveMode") }
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: "receiveMode").flatMap(ReceiveMode.init) ?? .automatic
    }
}

/// Names keys the way they are printed on Mac keycaps.
enum KeyLabel {
    private static let names: [Int: String] = {
        var names: [Int: String] = [
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
                            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, code) in functionKeys.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    /// Held modifiers in Apple's order.
    static func modifiers(_ flags: CGEventFlags) -> [String] {
        [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
    }

    /// The key itself, without the modifiers that would change its character.
    static func name(of event: CGEvent) -> String {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let name = names[code] { return name }
        let bare = event.copy()
        bare?.flags = []
        let characters = bare.flatMap { NSEvent(cgEvent: $0) }?.charactersIgnoringModifiers ?? ""
        return characters.isEmpty ? "Key \(code)" : characters.uppercased()
    }

    /// Text the key types, or nil for shortcuts and keys that move, edit or control.
    static func typed(by event: CGEvent) -> String? {
        guard !event.flags.contains(.maskCommand), !event.flags.contains(.maskControl),
              let characters = NSEvent(cgEvent: event)?.characters, !characters.isEmpty else { return nil }
        // Arrows and function keys report private-use characters.
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            !(0xF700...0xF8FF).contains(scalar.value) && scalar.properties.generalCategory != .control
        }
        return printable ? characters : nil
    }
}

/// A short message pinned to the top (or bottom) of the screen.
struct OverlayBanner: Equatable {
    var icon: String
    var title: String
    var detail: String

    static let sending = OverlayBanner(icon: "cursorarrow.motionlines", title: "Sharing your pointer",
                                       detail: "Release ⌘ to stop · ⌘↩ to type on the other Mac")
    static let typing = OverlayBanner(icon: "keyboard", title: "Typing on the other Mac",
                                      detail: "Your keys and text show on its screen · ⌘Esc to stop")
    static let copied = OverlayBanner(icon: "doc.on.clipboard", title: "Copied what they typed",
                                      detail: "Press ⌘V to paste it")

    static func request(from name: String, mode: ReceiveMode) -> OverlayBanner {
        OverlayBanner(icon: "cursorarrow.rays", title: "\(name) wants to share its pointer",
                      detail: mode == .hold ? "Hold ⌘ Command to let it in" : "Tap ⌘ Command to let it in · ⌘Esc to ignore")
    }

    static func receiving(from name: String, mode: ReceiveMode) -> OverlayBanner {
        OverlayBanner(icon: "cursorarrow.rays", title: "Receiving \(name)’s pointer",
                      detail: mode == .hold ? "Release ⌘ to stop" : "⌘Esc to stop")
    }

    static func typing(from name: String) -> OverlayBanner {
        OverlayBanner(icon: "keyboard", title: "\(name) is typing",
                      detail: "Their keys show at the bottom · ⌘V pastes their text")
    }
}

struct NoticeBanner: View {
    let banner: OverlayBanner
    let color: CursorColor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color.stroke)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(banner.detail)
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

/// The keys the sender is holding, drawn as keycaps.
struct KeycapRow: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(ELStyle.ink)
                    .padding(.horizontal, key.count > 1 ? 14 : 0)
                    .frame(minWidth: 52, minHeight: 52)
                    .background(ELStyle.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 0, y: 3)
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            }
        }
    }
}

/// What the sender has typed so far in the current burst.
struct TypedTextBubble: View {
    let text: String
    let color: CursorColor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(text)
                .lineLimit(3)
                .truncationMode(.head)
            Rectangle()
                .fill(color.stroke)
                .frame(width: 2, height: 22)
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(ELStyle.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 640)
        .fixedSize(horizontal: false, vertical: true)
        .background(ELStyle.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.stroke.opacity(0.6), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

final class NoticeModel: ObservableObject {
    @Published var banner: OverlayBanner?
}

private struct NoticeView: View {
    @ObservedObject var model: NoticeModel
    @ObservedObject var settings = CursorSettings.shared

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if let banner = model.banner {
                    NoticeBanner(banner: banner, color: settings.color)
                        .padding(.top, 48)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .allowsHitTesting(false)
    }
}

/// A click-through banner across the top of the sending Mac's screen.
final class NoticeWindow: NSWindow {
    private let model = NoticeModel()
    private var target: OverlayBanner?
    private var orderOutWork: DispatchWorkItem?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: NoticeView(model: model))
        host.sizingOptions = []
        contentView = host
    }

    func show(_ banner: OverlayBanner, on frame: CGRect) {
        orderOutWork?.cancel()
        orderOutWork = nil
        target = banner
        if self.frame != frame { setFrame(frame, display: false) }
        guard isVisible else {
            // Put the empty view on screen first so the entrance animates.
            orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in self?.applyTarget() }
            return
        }
        applyTarget()
    }

    func hide() {
        target = nil
        applyTarget()
        guard isVisible, orderOutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, target == nil else { return }
            orderOutWork = nil
            orderOut(nil)
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func applyTarget() {
        guard model.banner != target else { return }
        withAnimation(target == nil ? .easeOut(duration: 0.25) : .spring(response: 0.32, dampingFraction: 0.82)) {
            model.banner = target
        }
    }
}

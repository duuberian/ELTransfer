import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var status: MenuStatus
    @ObservedObject private var updater = AppUpdater.shared
    @ObservedObject private var receive = ReceiveSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ELTransfer").font(.system(size: 17, weight: .semibold))
                    Text("Version \(updater.currentVersion) (build \(updater.currentBuild))")
                        .font(.system(size: 12))
                        .foregroundStyle(ELStyle.muted)
                        .textSelection(.enabled)
                }
            }

            card {
                sectionTitle("Permissions")
                permissionRow("Accessibility", granted: status.accessibilityGranted,
                              pane: "Privacy_Accessibility") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
                    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
                }
                Divider().overlay(ELStyle.line)
                permissionRow("Input Monitoring", granted: status.inputMonitoringGranted,
                              pane: "Privacy_ListenEvent") { _ = CGRequestListenEventAccess() }
            }

            card {
                sectionTitle("Receiving")
                Picker("Let a shared pointer in", selection: $receive.mode) {
                    ForEach(ReceiveMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(receive.mode.explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(ELStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(ELStyle.line)
                sectionTitle("Sending")
                Text("Hold ⌘ Command and push the cursor to a screen edge to share it. While sharing, press ⌘↩ to type on the other Mac: your shortcuts show there as keys, and what you type lands on its clipboard for ⌘V. ⌘Esc stops.")
                    .font(.system(size: 11))
                    .foregroundStyle(ELStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            card {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: updater.availableVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(ELStyle.muted)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updateTitle).font(.system(size: 13, weight: .semibold))
                        Text("New updates appear in the ELTransfer menu, which opens automatically when a new release is found.")
                            .font(.system(size: 11))
                            .foregroundStyle(ELStyle.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(updater.availableVersion == nil ? "Check Now…" : "Review Update…") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canShowUpdate)
                }
                Divider().overlay(ELStyle.line)
                LabeledContent("Latest version", value: updater.latestVersion ?? "Not checked yet")
                    .font(.system(size: 12))
                if let message = updater.updateStatus {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(updater.lastCheckFailed ? Color.orange : ELStyle.muted)
                        .textSelection(.enabled)
                }
            }

            Text("ELTransfer checks for updates when it starts, whenever you open Settings, and every minute while running. Updates install only when you choose to install them.")
                .font(.system(size: 11))
                .foregroundStyle(ELStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .padding(.top, 18) // Clears the transparent title bar.
        .frame(width: 420)
        .background(ELStyle.paper)
        .foregroundStyle(ELStyle.ink)
        .onAppear { updater.checkForUpdates() }
        .localPointer("settings")
    }

    private var updateTitle: String {
        if !updater.isAvailable { return "Updates are unavailable in development builds" }
        if let version = updater.availableVersion { return "ELTransfer \(version) is available" }
        if updater.lastCheckFailed { return "Update needs attention" }
        return updater.latestVersion == nil ? "Check for updates" : "You’re up to date"
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ELStyle.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ELStyle.line, lineWidth: 1))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(ELStyle.muted)
    }

    /// `register` asks macOS for the permission first, so ELTransfer is already listed
    /// in the pane (even after its entry was removed) and the user only flips the switch.
    private func permissionRow(_ name: String, granted: Bool, pane: String,
                               register: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text(name).font(.system(size: 13))
            Spacer()
            if granted {
                Text("Allowed").font(.system(size: 12)).foregroundStyle(ELStyle.muted)
            } else {
                Button("Open Settings…") {
                    register()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let status: MenuStatus
    private var window: NSWindow?
    var onVisibilityChange: ((Bool) -> Void)?

    init(status: MenuStatus) {
        self.status = status
    }

    var isVisible: Bool { window?.isVisible == true }

    func close() {
        window?.close()
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: true)
            window.title = "ELTransfer Settings"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(status: status))
            window.setContentSize(window.contentView?.fittingSize ?? .zero)
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }
}

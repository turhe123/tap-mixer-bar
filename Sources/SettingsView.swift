import ServiceManagement
import SwiftUI

/// Preferences: launch at login, silent-app visibility, maximum boost and the solo hotkey.
struct SettingsView: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage("showSilent") private var showSilent = false
    @AppStorage("maxBoost") private var maxBoost = 150
    @AppStorage("soloHotkey") private var soloHotkey = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Show silent apps", isOn: $showSilent)
            Picker("Maximum boost", selection: $maxBoost) {
                Text("100%").tag(100)
                Text("125%").tag(125)
                Text("150%").tag(150)
            }
            .onChange(of: maxBoost) { _, value in model.applyMaxBoost(value) }
            Toggle("Solo hotkey (⌃⌥⌘M mutes all but the frontmost app)", isOn: $soloHotkey)
                .onChange(of: soloHotkey) { _, enabled in SoloHotkey.shared.setEnabled(enabled, model: model) }
            if soloHotkey && !SoloHotkey.shared.isTrusted {
                Text("Grant Accessibility access in System Settings › Privacy & Security for the hotkey to work in other apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Support / Donate ❤️") { Support.openDonate() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

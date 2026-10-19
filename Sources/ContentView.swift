import SwiftUI

/// The menu bar popover: notices, the per-app mixer list and the footer actions.
struct ContentView: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showSilent") private var showSilent = false

    private var visibleApps: [AudioApp] {
        model.apps.filter { showSilent || $0.isPlaying || model.gain(for: $0) != 1 || model.isMuted($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TapMixerBar").font(.headline)
            if !model.isSupported {
                Notice(symbol: "exclamationmark.triangle.fill",
                       text: "Per-app volume needs macOS 14.2 or later. Please update macOS to use TapMixerBar.")
            } else {
                if model.needsExplanation { explanation }
                if model.permissionProblem { permissionBanner }
                if visibleApps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "speaker.fill").font(.title2).foregroundStyle(.secondary)
                        Text("Nothing is playing right now").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(visibleApps) { AppRow(app: $0) }
                        }
                    }
                    .frame(maxHeight: 340)
                }
            }
            Divider()
            HStack {
                Button("Reset All") { model.resetAll() }
                    .disabled(model.gains.isEmpty && model.muted.isEmpty)
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            Button("Support / Donate ❤️") { Support.openDonate() }
                .buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 340)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One quick permission", systemImage: "waveform.badge.mic").font(.subheadline.bold())
            Text("To change an app's volume, TapMixerBar re-routes that app's sound through a private audio tap. macOS will ask you to allow System Audio Recording. Audio is processed live and never recorded or sent anywhere.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Continue") { model.acknowledgeExplanation() }.controlSize(.small)
        }
        .padding(10)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Notice(symbol: "hand.raised.fill",
                   text: "TapMixerBar couldn't tap app audio. Allow it under Privacy & Security › System Audio Recording.")
            HStack {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Try Again") { model.retryTaps() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A single mixer row: icon, name, slider, percent label and mute toggle.
struct AppRow: View {
    @EnvironmentObject private var model: MixerModel
    @AppStorage("maxBoost") private var maxBoost = 150
    let app: AudioApp

    var body: some View {
        let locked = model.isLocked(app)
        let muted = model.isMuted(app)
        let gain = model.gain(for: app)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                Text(app.name).lineLimit(1)
                if locked { Image(systemName: "lock.fill").foregroundStyle(.secondary).help("This app's audio is protected") }
                Spacer()
                Text("\(Int((gain * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                Button { model.toggleMute(app) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(muted ? .red : .primary)
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .disabled(locked)
                .help(muted ? "Unmute" : "Mute")
            }
            Slider(value: Binding(get: { min(gain, Double(maxBoost) / 100) },
                                  set: { model.setGain($0, for: app) }),
                   in: 0...Double(maxBoost) / 100)
                .controlSize(.small)
                .disabled(locked || muted)
        }
    }
}

/// Small icon + text callout used for warnings.
struct Notice: View {
    let symbol: String
    let text: String

    var body: some View {
        Label { Text(text).font(.caption).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(.orange)
        }
    }
}

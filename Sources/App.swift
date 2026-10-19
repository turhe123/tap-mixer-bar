import SwiftUI

/// App entry point: a window-style menu bar extra plus a Settings scene.
@main
struct TapMixerBarApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.anyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Opens the developer's donation page.
enum Support {
    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}

import AppKit
import ApplicationServices

/// Watches for ⌃⌥⌘M system-wide and toggles "mute everything except the frontmost app".
/// Global key monitoring needs Accessibility access, which is requested when the hotkey is enabled.
final class SoloHotkey {
    static let shared = SoloHotkey()
    private var monitors: [Any] = []

    var isTrusted: Bool { AXIsProcessTrusted() }

    func setEnabled(_ enabled: Bool, model: MixerModel) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard enabled else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        let matches: (NSEvent) -> Bool = { event in
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option, .command]
                && event.charactersIgnoringModifiers?.lowercased() == "m"
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak model] event in
            if matches(event) { model?.toggleSoloFrontmost() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak model] event in
            guard matches(event) else { return event }
            model?.toggleSoloFrontmost()
            return nil
        }) { monitors.append(local) }
    }
}

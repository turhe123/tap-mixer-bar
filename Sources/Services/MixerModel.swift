import AppKit
import CoreAudio
import Foundation

/// One Core Audio client process, decorated with the owning app's name and icon.
struct AudioApp: Identifiable, Equatable {
    let id: AudioObjectID
    let bundleID: String
    /// Bundle ID of the user-facing app (e.g. Chrome for "Chrome Helper"), used for the solo hotkey.
    let ownerBundleID: String
    let name: String
    let icon: NSImage
    let isPlaying: Bool
}

/// Central state: discovers audio processes, persists per-app gains and keeps one
/// `ProcessTap` alive for every app whose effective gain differs from 100%.
final class MixerModel: ObservableObject {
    static let maxGain = 1.5
    private static let gainsKey = "gains", mutedKey = "muted", explainedKey = "explainedCapture"

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var gains: [String: Double]
    @Published private(set) var muted: Set<String>
    @Published private(set) var locked: Set<String> = []
    @Published var permissionProblem = false
    @Published private(set) var needsExplanation: Bool

    let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0))

    private var taps: [AudioObjectID: AnyObject] = [:]
    private var anyTapSucceeded = false
    private var soloMuted: Set<String>?
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var anyMuted: Bool { apps.contains { isMuted($0) } }

    init() {
        let stored = defaults.dictionary(forKey: Self.gainsKey) as? [String: Double] ?? [:]
        gains = stored.mapValues { min(max($0, 0), Self.maxGain) }
        muted = Set(defaults.stringArray(forKey: Self.mutedKey) ?? [])
        needsExplanation = !defaults.bool(forKey: Self.explainedKey)
        if defaults.bool(forKey: "soloHotkey") {
            DispatchQueue.main.async { SoloHotkey.shared.setEnabled(true, model: self) }
        }
        guard isSupported else { return }
        refresh()
        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.rebuildAll() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    // MARK: - Queries

    func gain(for app: AudioApp) -> Double { gains[app.bundleID] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.bundleID) }
    func isLocked(_ app: AudioApp) -> Bool { locked.contains(app.bundleID) }

    // MARK: - Mutations

    func setGain(_ value: Double, for app: AudioApp) {
        let clamped = min(max(value, 0), Self.maxGain)
        if abs(clamped - 1) < 0.005 { gains[app.bundleID] = nil } else { gains[app.bundleID] = clamped }
        persist()
    }

    func toggleMute(_ app: AudioApp) {
        if muted.contains(app.bundleID) { muted.remove(app.bundleID) } else { muted.insert(app.bundleID) }
        persist()
    }

    func resetAll() {
        gains = [:]
        muted = []
        soloMuted = nil
        persist()
    }

    /// Clamps every stored gain to the user's chosen maximum boost.
    func applyMaxBoost(_ percent: Int) {
        let limit = Double(percent) / 100
        gains = gains.mapValues { min($0, limit) }
        persist()
    }

    /// Clears the permission banner and tries creating taps again.
    func retryTaps() {
        permissionProblem = false
        sync()
    }

    func acknowledgeExplanation() {
        defaults.set(true, forKey: Self.explainedKey)
        needsExplanation = false
        sync()
    }

    /// Mutes every app except the frontmost one; calling again restores the previous state.
    func toggleSoloFrontmost() {
        if let previous = soloMuted {
            muted.subtract(previous)
            soloMuted = nil
        } else {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let targets = Set(apps.filter { $0.ownerBundleID != front && !muted.contains($0.bundleID) }.map(\.bundleID))
            muted.formUnion(targets)
            soloMuted = targets
        }
        persist()
    }

    private func persist() {
        defaults.set(gains, forKey: Self.gainsKey)
        defaults.set(Array(muted), forKey: Self.mutedKey)
        sync()
    }

    // MARK: - Discovery

    /// Re-reads the process object list and running-output flags.
    func refresh() {
        guard isSupported else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var found: [AudioApp] = []
        for object in CA.objectList(CA.system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = CA.value(object, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0, pid != ownPID,
                  let bundleID = CA.string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty,
                  let running = NSRunningApplication(processIdentifier: pid) else { continue }
            let playing = (CA.value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            let owner = Self.owningApp(of: running)
            found.append(AudioApp(id: object, bundleID: bundleID,
                                  ownerBundleID: owner?.bundleIdentifier ?? bundleID,
                                  name: owner.map { FileManager.default.displayName(atPath: $0.bundlePath) }
                                      ?? running.localizedName ?? bundleID,
                                  icon: owner.map { NSWorkspace.shared.icon(forFile: $0.bundlePath) }
                                      ?? running.icon ?? NSImage(),
                                  isPlaying: playing))
        }
        found.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if found != apps { apps = found }
        sync()
    }

    /// Helper processes live inside their parent's bundle; walk up to the outermost `.app`.
    private static func owningApp(of app: NSRunningApplication) -> Bundle? {
        guard let path = app.bundleURL?.path, let range = path.range(of: ".app/") else { return nil }
        return Bundle(path: String(path[..<range.lowerBound]) + ".app")
    }

    // MARK: - Tap management

    private func rebuildAll() {
        guard #available(macOS 14.2, *) else { return }
        taps.values.forEach { ($0 as? ProcessTap)?.stop() }
        taps = [:]
        sync()
    }

    /// Reconciles running taps with the desired per-app gains.
    private func sync() {
        guard #available(macOS 14.2, *) else { return }
        let liveIDs = Set(apps.map(\.id))
        for (id, tap) in taps where !liveIDs.contains(id) {
            (tap as? ProcessTap)?.stop()
            taps[id] = nil
        }
        for app in apps {
            let target = Float(isMuted(app) ? 0 : gain(for: app))
            let wanted = !needsExplanation && !isLocked(app) && target != 1
            if let tap = taps[app.id] as? ProcessTap {
                if wanted { tap.gain.value = target } else { tap.stop(); taps[app.id] = nil }
            } else if wanted && app.isPlaying && !permissionProblem {
                let tap = ProcessTap(processObject: app.id, gain: target)
                do {
                    try tap.start()
                    taps[app.id] = tap
                    anyTapSucceeded = true
                    permissionProblem = false
                } catch {
                    // Once taps are known to work, a single failure means this app's audio is protected.
                    if anyTapSucceeded { locked.insert(app.bundleID) } else { permissionProblem = true }
                }
            }
        }
    }
}

import CoreAudio
import Foundation

/// Thin, typed wrappers around the C-style `AudioObjectGetPropertyData` family.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size scalar property, returning `nil` on any Core Audio error.
    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) -> T? {
        var addr = address(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    /// Reads a CFString property (bundle IDs, device UIDs).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = result?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Reads a variable-length list of object IDs.
    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// UID of the current default output device, used as the aggregate's main sub-device.
    static func defaultOutputUID() -> String? {
        guard let device = value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    /// Registers a block listener; returns the block so it can be removed later, or nil on failure.
    @discardableResult
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       queue: DispatchQueue = .main, _ block: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var addr = address(selector)
        let listener: AudioObjectPropertyListenerBlock = { _, _ in block() }
        return AudioObjectAddPropertyListenerBlock(object, &addr, queue, listener) == noErr ? listener : nil
    }

    static func unlisten(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         queue: DispatchQueue = .main, _ listener: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(selector)
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, listener)
    }
}

/// A lock-free-enough box shared between the main thread (writer) and the real-time IO proc (reader).
final class GainBox {
    var value: Float
    init(_ value: Float) { self.value = value }
}

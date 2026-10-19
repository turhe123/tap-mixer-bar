import AudioToolbox
import CoreAudio
import Foundation

/// Errors raised while building a tap; `status` is the raw OSStatus for diagnostics.
struct TapError: Error {
    let stage: String
    let status: OSStatus
}

/// Owns one Core Audio process tap plus the private aggregate device that plays the
/// gain-adjusted stream back out through the current default output device.
@available(macOS 14.2, *)
final class ProcessTap {
    let processObject: AudioObjectID
    let gain: GainBox

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let ioQueue = DispatchQueue(label: "com.turhe123.tapmixerbar.io", qos: .userInteractive)

    init(processObject: AudioObjectID, gain: Float) {
        self.processObject = processObject
        self.gain = GainBox(gain)
    }

    deinit { stop() }

    /// Creates the muted tap, wraps it in an aggregate device and starts the IO proc.
    func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "TapMixerBar tap"

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { tapID = AudioObjectID(kAudioObjectUnknown); throw TapError(stage: "tap", status: status) }

        guard let outputUID = CA.defaultOutputUID() else { stop(); throw TapError(stage: "output", status: -1) }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TapMixerBar-\(processObject)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw TapError(stage: "aggregate", status: status) }

        do { try startIOProc() } catch { stop(); throw error }

        // A sample-rate change invalidates the running IO proc, so rebuild it.
        rateListener = CA.listen(aggregateID, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            self?.stopIOProc()
            try? self?.startIOProc()
        }
    }

    /// Tears everything down in reverse order. Safe to call repeatedly.
    func stop() {
        if let listener = rateListener {
            CA.unlisten(aggregateID, kAudioDevicePropertyNominalSampleRate, listener)
            rateListener = nil
        }
        stopIOProc()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func startIOProc() throws {
        let gain = self.gain
        var status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, output, _ in
            ProcessTap.render(input: input, output: output, gain: gain.value)
        }
        guard status == noErr, let procID = ioProcID else { throw TapError(stage: "ioproc", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stopIOProc(); throw TapError(stage: "start", status: status) }
    }

    private func stopIOProc() {
        guard let procID = ioProcID else { return }
        AudioDeviceStop(aggregateID, procID)
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
    }

    /// Real-time callback body: copies tapped Float32 samples to the output with gain and soft clipping.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // Tap streams follow any input streams of the output device, so read from the tail.
        let offset = max(0, inputs.count - outputs.count)
        for index in 0..<outputs.count {
            guard let dst = outputs[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let dstCount = Int(outputs[index].mDataByteSize) / MemoryLayout<Float>.size
            let srcIndex = min(offset + index, inputs.count - 1)
            var copied = 0
            if srcIndex >= 0, let src = inputs[srcIndex].mData?.assumingMemoryBound(to: Float.self) {
                copied = min(dstCount, Int(inputs[srcIndex].mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<copied { dst[i] = softClip(src[i] * gain) }
            }
            for i in copied..<max(copied, dstCount) { dst[i] = 0 }
        }
    }

    /// Linear up to the knee, then a tanh curve that approaches but never exceeds full scale.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.9
        let magnitude = abs(x)
        guard magnitude > knee else { return x }
        let shaped = knee + (1 - knee) * tanh((magnitude - knee) / (1 - knee))
        return x < 0 ? -shaped : shaped
    }
}

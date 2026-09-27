import Accelerate
import AppKit
import CoreAudio
import os

/// What the music sounds like right now. Read every frame by the views that already animate
/// (the dot displays and the background); nothing is published, so nothing extra re-renders.
struct AudioLevels: Sendable {
    /// 0...1 per band: bass, low mids, high mids, treble. Jumps up instantly, falls like a VU meter.
    var bands = SIMD4<Float>.zero
    /// 0...1: jumps when the bass hits, falls back over ~0.3s.
    var kick: Float = 0
    /// 0...1: overall loudness, smoothed over about a second.
    var energy: Float = 0
    /// Seconds to add to the background's flow clock: it runs faster when the song is loud and surges on hits.
    var flow: Double = 0
}

/// Listens to Apple Music's audio output with a Core Audio process tap (macOS 14.2+; asks for
/// "System Audio Recording" permission the first time) and turns it into `AudioLevels`.
/// Only runs while Music is playing.
final class MusicAudio: @unchecked Sendable {
    static let shared = MusicAudio()

    private let state = OSAllocatedUnfairLock(initialState: AudioLevels())
    var levels: AudioLevels { state.withLock { $0 } }

    private let control = DispatchQueue(label: "Auraverse.MusicAudio")
    private let io = DispatchQueue(label: "Auraverse.MusicAudio.io", qos: .userInteractive)

    // Only touched on `control`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID]?
    private var running = false

    // Only touched on `io`.
    private var analyzer: SpectrumAnalyzer?

    /// Called on every poll of Music. Cheap when nothing changed.
    func update(playing: Bool) {
        control.async { playing ? self.start() : self.stop() }
    }

    private func start() {
        // Music's audio process(es). They only exist once Music has played something, and change if it relaunches.
        let processes = Self.processObjects().filter { Self.bundleID(of: $0)?.hasPrefix("com.apple.Music") == true }
        if processes != tappedProcesses {
            teardown()
            if !processes.isEmpty { setUp(processes) }
            tappedProcesses = processes
        }
        guard let procID, !running else { return }
        running = AudioDeviceStart(deviceID, procID) == noErr
    }

    private func stop() {
        guard running, let procID else { return }
        AudioDeviceStop(deviceID, procID)
        running = false
        io.async { self.analyzer?.reset() }
        state.withLock { levels in levels = AudioLevels(flow: levels.flow) } // keep the flow clock where it is
    }

    private func setUp(_ processes: [AudioObjectID]) {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { return }

        // A tap is read through a private aggregate device built around the current output device.
        guard let output = Self.defaultOutputUID(), let format = Self.tapFormat(tapID),
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return teardown() }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Auraverse",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == noErr else { return teardown() }

        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(max(format.mChannelsPerFrame, 1))
        io.async { self.analyzer = SpectrumAnalyzer(sampleRate: format.mSampleRate) }
        var mono = [Float](repeating: 0, count: 4096)

        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, io) { [weak self] _, input, _, _, _ in
            guard let self, self.analyzer != nil else { return }
            // Mix the tap's channels down to mono.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            let frames = interleaved ? Int(first.mDataByteSize) / 4 / channels : Int(first.mDataByteSize) / 4
            if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
            mono.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames { out[i] = 0 }
                if interleaved {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames {
                        for c in 0..<channels { out[i] += samples[i * channels + c] }
                    }
                } else {
                    for buffer in buffers {
                        guard let d = buffer.mData else { continue }
                        let samples = d.assumingMemoryBound(to: Float.self)
                        for i in 0..<min(frames, Int(buffer.mDataByteSize) / 4) { out[i] += samples[i] }
                    }
                }
                self.analyzer!.add(UnsafeBufferPointer(rebasing: out[0..<frames])) { levels in
                    self.state.withLock { $0 = levels }
                }
            }
        }
        if status != noErr { teardown() }
    }

    private func teardown() {
        if let procID {
            if running { AudioDeviceStop(deviceID, procID) }
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        running = false
    }

    // MARK: Core Audio properties

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        string(process, kAudioProcessPropertyBundleID)
    }

    private static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

/// Turns a stream of mono samples into `AudioLevels`: an FFT every ~10ms, energy in four bands,
/// each normalized against its own recent peak (so quiet and loud songs both fill the meters).
struct SpectrumAnalyzer {
    static let log2n: vDSP_Length = 10
    static let size = 1 << 10 // ~21ms at 48kHz
    static let hop = size / 2
    /// Band edges in Hz: bass, low mids, high mids, treble.
    static let edges: [Double] = [30, 150, 600, 2500, 10000]
    /// How far below a band's recent peak reads as empty.
    static let range: Float = 24 // dB

    private let setup: FFTSetup
    private let window: [Float]
    private let bins: [Range<Int>]
    private let hopSeconds: Float

    private var pending: [Float] = []
    private var peaks = SIMD4<Float>(repeating: 0)
    private var bassAverage: Float = 0
    private(set) var levels = AudioLevels()

    init(sampleRate: Double) {
        setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        let binHz = sampleRate / Double(Self.size)
        bins = (0..<4).map { b in
            let low = max(Int((Self.edges[b] / binHz).rounded()), 1)
            return low..<max(Int((Self.edges[b + 1] / binHz).rounded()), low + 1)
        }
        hopSeconds = Float(Double(Self.hop) / sampleRate)
        pending.reserveCapacity(Self.size * 4)
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        bassAverage = 0
        levels = AudioLevels(flow: levels.flow)
    }

    /// Feeds samples in; calls `publish` after each analysis step.
    mutating func add(_ samples: UnsafeBufferPointer<Float>, publish: (AudioLevels) -> Void) {
        pending.append(contentsOf: samples)
        var changed = false
        while pending.count >= Self.size {
            analyze(pending[0..<Self.size])
            pending.removeFirst(Self.hop)
            changed = true
        }
        if changed { publish(levels) }
    }

    private mutating func analyze(_ frame: ArraySlice<Float>) {
        let windowed = vDSP.multiply(frame, window)
        var real = [Float](repeating: 0, count: Self.size / 2)
        var imag = [Float](repeating: 0, count: Self.size / 2)
        var power = [Float](repeating: 0, count: Self.size / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes {
                    vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // zrip packs the Nyquist bin here; bin 0 (DC) is never used
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(Self.size / 2))
            }
        }

        var raw = SIMD4<Float>.zero
        for b in 0..<4 {
            let amplitude = bins[b].reduce(Float(0)) { $0 + power[min($1, power.count - 1)] }.squareRoot()
            // Peak decays with a ~10s half-life; the floor keeps near-silence from filling the meter.
            peaks[b] = max(amplitude, peaks[b] * pow(0.5, hopSeconds / 10), 0.05)
            let db = 20 * log10(max(amplitude / peaks[b], 1e-6))
            raw[b] = min(max(1 + db / Self.range, 0), 1)
        }

        // Meters: instant attack, fall the full height in 0.35s.
        levels.bands = pointwiseMax(pointwiseMax(raw, levels.bands - hopSeconds / 0.35), .zero)

        // A hit is the bass rising above its own recent average (~0.25s), so a held bass note doesn't count.
        let onset = max(raw[0] - bassAverage, 0)
        bassAverage += (raw[0] - bassAverage) * min(hopSeconds / 0.25, 1)
        levels.kick = max(min(onset * 2.5, 1), levels.kick - hopSeconds / 0.3)

        let loudness = (raw[0] + raw[1] + raw[2] + raw[3]) / 4
        levels.energy += (loudness - levels.energy) * min(hopSeconds / 1.0, 1)
        levels.flow += Double(hopSeconds * (levels.energy * 2 + levels.kick * 6))
    }
}

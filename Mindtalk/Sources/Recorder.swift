import AVFoundation
import CoreAudio
import os

/// Records the chosen input into 16 kHz mono Float samples. Samples live only
/// in memory; an input queue selects its device without changing system settings.
final class Recorder: @unchecked Sendable {
    var onLevel: (@Sendable (Float) -> Void)?
    /// Every 16 kHz chunk as it arrives (meetings: live transcription, the file on
    /// disk) — also the last one, handed over while stopping.
    var onChunk: (@Sendable ([Float]) -> Void)?
    /// The input went away mid-recording. Delivered on the main queue.
    var onInterrupted: (@Sendable () -> Void)?
    /// The input is still there but sends nothing but zeros — no signal at all, which
    /// a quiet room never gives (a Bluetooth headset whose link was taken over).
    /// Once per start, on the main queue.
    var onSignalLost: (@Sendable () -> Void)?

    /// The device being recorded from — the chosen one, or the system input it resolved to.
    private(set) var inputDevice: AudioDeviceID?
    /// Recording from AirPods or another Bluetooth headset.
    var usesBluetooth: Bool { inputDevice.map(Self.isBluetooth) ?? false }

    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "ai.mindact.mindtalk.recorder")
    private var queue: AudioQueueRef?
    private var context: Unmanaged<QueueContext>?
    private var generation: UUID?
    private var running = false
    /// Stopping: the last, partly filled buffer is still on its way — kept, not re-queued.
    private var stopping = false
    /// When audio last arrived — a mic that goes quiet without saying so is caught
    /// by its silence. Nil until the first buffer: a headset is given time to start.
    private var lastAudio: Date?
    /// The input is Bluetooth: AirPods take a few seconds to switch to their headset
    /// mode before the first buffer comes.
    private var bluetoothInput = false
    private var hardwareStarted = false
    private var interruptionReported = false
    /// Since when every sample has been exactly zero (nil while there's signal).
    private var zeroSince: Date?
    private var startedAt = Date()
    private var signalLossReported = false
    #if DEBUG
    var zerosAfter: TimeInterval?
    #endif
    private var samples: [Float] = []
    /// False for the level preview in the mic picker — nothing is kept.
    private let keepSamples: Bool

    private final class QueueContext {
        weak var recorder: Recorder?
        let generation = UUID()
        init(_ recorder: Recorder) { self.recorder = recorder }
    }

    init(keepSamples: Bool = true) {
        self.keepSamples = keepSamples
    }

    deinit {
        // A callback can temporarily be the last owner of this recorder. Leave
        // native teardown to another queue so disposal never waits on itself.
        if let queue {
            let context = context
            DispatchQueue.global(qos: .utility).async { Self.dispose(queue, context: context) }
        }
    }

    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                            channels: 1, interleaved: false)!

    static var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Starts recording from `device`, or from the system input when nil.
    func start(device: AudioDeviceID? = nil) throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        lock.lock()
        if running { lock.unlock(); return }
        samples = []
        lock.unlock()

        // Audio Queue does the hardware conversion. Input queues require
        // interleaved PCM; mono samples have the same memory layout either way.
        var format = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var created: AudioQueueRef?
        try Self.check(AudioQueueNewInputWithDispatchQueue(
            &created, &format, 0, callbackQueue, Self.inputBlock(for: self)), "new queue")
        guard let created else { throw Self.microphoneError() }

        let state = Unmanaged.passRetained(QueueContext(self))
        var listenerAdded = false
        var started = false
        defer {
            if !started {
                lock.lock()
                queue = nil; context = nil; generation = nil; running = false
                lock.unlock()
                if listenerAdded {
                    AudioQueueRemovePropertyListener(created, kAudioQueueProperty_IsRunning,
                                                     Self.propertyChanged, state.toOpaque())
                }
                AudioQueueDispose(created, true)
                Self.release(state)
            }
        }

        if let device {
            guard let deviceUID = Self.deviceUID(device) else {
                Self.log.error("start: no UID for device \(device, privacy: .public)")
                throw Self.microphoneError()
            }
            var uid = Unmanaged.passUnretained(deviceUID)
            let status = withExtendedLifetime(deviceUID) {
                AudioQueueSetProperty(created, kAudioQueueProperty_CurrentDevice,
                                      &uid, UInt32(MemoryLayout<Unmanaged<CFString>>.size))
            }
            try Self.check(status, "select device")
        }
        try Self.check(AudioQueueAddPropertyListener(created, kAudioQueueProperty_IsRunning,
                                                       Self.propertyChanged, state.toOpaque()), "listener")
        listenerAdded = true
        // 3 × 32 ms: enough slack for the callback, and stopping in order (which
        // fills what's queued) only waits about a tenth of a second.
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            try Self.check(AudioQueueAllocateBuffer(created, 2048, &buffer), "allocate")
            guard let buffer else { throw Self.microphoneError() }
            try Self.check(AudioQueueEnqueueBuffer(created, buffer, 0, nil), "enqueue")
        }
        let input = device ?? Self.defaultInput()
        let bluetooth = input.map(Self.isBluetooth) ?? false
        lock.lock()
        queue = created; context = state; generation = state.takeUnretainedValue().generation
        running = true; stopping = false; hardwareStarted = false; interruptionReported = false
        lastAudio = nil; bluetoothInput = bluetooth
        zeroSince = nil; startedAt = Date(); signalLossReported = false
        lock.unlock()
        inputDevice = input
        // A device that is changing format (AirPods switching to their headset
        // mode, a call app taking the mic) asks to be tried again a moment later.
        var status = AudioQueueStart(created, nil)
        for _ in 0..<3 where status == OSStatus(kAudioQueueErr_CannotStartYet) {
            Thread.sleep(forTimeInterval: 0.08)
            status = AudioQueueStart(created, nil)
        }
        try Self.check(status, "start")
        started = true
    }

    /// Stops the mic and hands back everything recorded since `start()`.
    func stop() -> [Float] {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        lock.lock()
        let stoppedQueue = queue
        let wasRunning = running
        stopping = true
        lock.unlock()
        let began = Date()
        if let stoppedQueue, wasRunning {
            // The last word ends in a partly filled buffer: an orderly stop hands it
            // over (kept by the callback, not re-queued) before the queue goes quiet.
            if AudioQueueStop(stoppedQueue, false) == noErr {
                let deadline = Date().addingTimeInterval(0.3)
                while Self.isRunning(stoppedQueue), Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            }
            callbackQueue.sync {}     // let delivered buffers land
            Self.log.info("stop: drained in \(Int(Date().timeIntervalSince(began) * 1000), privacy: .public) ms")
        }
        lock.lock()
        let stoppedContext = context
        queue = nil; context = nil; generation = nil; running = false; stopping = false
        lock.unlock()
        // Its buffers are in: the queue is let go of elsewhere, so the samples aren't
        // kept waiting for it (a Bluetooth device can take a while to close).
        if let stoppedQueue {
            DispatchQueue.global(qos: .utility).async { Self.dispose(stoppedQueue, context: stoppedContext) }
        }
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples = []
        return out
    }

    private static func dispose(_ queue: AudioQueueRef, context: Unmanaged<QueueContext>?) {
        if let context {
            AudioQueueRemovePropertyListener(queue, kAudioQueueProperty_IsRunning,
                                             Self.propertyChanged, context.toOpaque())
        }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        if let context { release(context) }
    }

    /// Released a moment later: Core Audio doesn't promise that removing the
    /// listener waits for a call already under way, which still reads the context.
    private static func release(_ context: Unmanaged<QueueContext>) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { context.release() }
    }

    private static func isRunning(_ queue: AudioQueueRef) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &value, &size) == noErr && value != 0
    }

    /// Seconds since audio last arrived — 0 when not recording. Before the first
    /// buffer it counts from the end of a grace period: longer for Bluetooth, whose
    /// headset mode can take seconds to start.
    var silentFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard running && !stopping else { return 0 }
        if let lastAudio { return Date().timeIntervalSince(lastAudio) }
        return max(0, Date().timeIntervalSince(startedAt) - (bluetoothInput ? 5 : 1.5))
    }

    /// The system's input device right now.
    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// The Mac's sound goes to a Bluetooth headset: the default output, or the device
    /// alerts play on. A sound there while recording can cost the headset's mic.
    static var outputIsBluetooth: Bool {
        [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice].contains { selector in
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
            return status == noErr && id != 0 && isBluetooth(id)
        }
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func deviceUID(_ id: AudioDeviceID) -> CFString? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }

    private static func check(_ status: OSStatus, _ step: StaticString) throws {
        guard status != noErr else { return }
        log.error("\(step.description, privacy: .public) failed: OSStatus \(status, privacy: .public)")
        throw microphoneError(status)
    }

    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Recorder")

    private static func microphoneError(_ status: OSStatus = -1) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Hittar ingen fungerande mikrofon.")])
    }

    private static let propertyChanged: AudioQueuePropertyListenerProc = { pointer, queue, _ in
        guard let pointer else { return }
        let state = Unmanaged<QueueContext>.fromOpaque(pointer).takeUnretainedValue()
        guard let recorder = state.recorder else { return }
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioQueueGetProperty(queue, kAudioQueueProperty_IsRunning, &isRunning, &size) == noErr else { return }
        recorder.lock.lock()
        guard recorder.queue == queue, recorder.running, !recorder.stopping else { recorder.lock.unlock(); return }
        if isRunning != 0 { recorder.hardwareStarted = true }
        let interrupted = isRunning == 0 && recorder.hardwareStarted
        recorder.lock.unlock()
        if interrupted { recorder.reportInterruption(generation: state.generation) }
    }

    private func reportInterruption(generation expected: UUID) {
        lock.lock()
        guard running, generation == expected, !interruptionReported else { lock.unlock(); return }
        interruptionReported = true
        lock.unlock()
        // Do not dispose a queue from its own callback; callers may stop in
        // response to this notification.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = self.running && self.generation == expected
            self.lock.unlock()
            if stillCurrent { self.onInterrupted?() }
        }
    }

    private static func inputBlock(for recorder: Recorder) -> AudioQueueInputCallbackBlock {
        { [weak recorder] queue, buffer, _, _, _ in
            guard let recorder else { return }
            // Checked before the buffer is touched: once stop has let go of this
            // queue, its buffers may already be gone.
            recorder.lock.lock()
            guard recorder.running, recorder.queue == queue else { recorder.lock.unlock(); return }
            let count = Int(buffer.pointee.mAudioDataByteSize) / MemoryLayout<Float>.size
            let data = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            var chunk = Array(UnsafeBufferPointer(start: data, count: count))
            #if DEBUG
            // `--signal-test`: the signal dies after a few seconds, as a taken-over headset's does.
            if let after = recorder.zerosAfter, Date().timeIntervalSince(recorder.startedAt) > after {
                chunk = [Float](repeating: 0, count: chunk.count)
            }
            #endif
            var sum: Float = 0
            for value in chunk { sum += value * value }
            let rms: Float = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
            recorder.hardwareStarted = true
            if !chunk.isEmpty { recorder.lastAudio = Date() }
            // Pure zeros: no signal. A headset gives some while it starts up, so only
            // after the first three seconds, and only when it lasts a second and a half.
            var signalLost = false
            if !chunk.isEmpty {
                if chunk.allSatisfy({ $0 == 0 }) {
                    let now = Date()
                    if recorder.zeroSince == nil { recorder.zeroSince = now }
                    if !recorder.signalLossReported, now.timeIntervalSince(recorder.startedAt) > 3,
                       now.timeIntervalSince(recorder.zeroSince!) >= 1.5 {
                        recorder.signalLossReported = true
                        signalLost = true
                    }
                } else {
                    recorder.zeroSince = nil
                }
            }
            if recorder.keepSamples { recorder.samples += chunk }
            let generation = recorder.generation
            // Hold the lock through re-enqueueing so stop cannot dispose the
            // queue while a callback is still returning its buffer. While
            // stopping, the buffer is kept but not handed back.
            let status = recorder.stopping ? noErr : AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            recorder.lock.unlock()
            if !chunk.isEmpty { recorder.onChunk?(chunk) }
            recorder.onLevel?(min(1, rms * 12))
            if status != noErr, let generation { recorder.reportInterruption(generation: generation) }
            if signalLost, let generation {
                Self.log.error("input sends only zeros")
                DispatchQueue.main.async { [weak recorder] in
                    guard let recorder else { return }
                    recorder.lock.lock()
                    let current = recorder.running && recorder.generation == generation
                    recorder.lock.unlock()
                    if current { recorder.onSignalLost?() }
                }
            }
        }
    }

    /// Reads an audio file as 16 kHz mono (for the self-test).
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else { return [] }
        try file.read(into: input)
        let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)
        else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

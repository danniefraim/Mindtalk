import AVFoundation
import CoreAudio
import os

// MARK: - The other side of a call

/// When a meeting takes the Mac's sound: with headphones (the default), always, or never.
enum CallAudioMode: String, CaseIterable, Identifiable {
    case headphones, always, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .headphones: return String(localized: "Med hörlurar")
        case .always: return String(localized: "Alltid")
        case .never: return String(localized: "Aldrig")
        }
    }
}

/// The Mac's own sound, for a meeting on the Mac: the others in Teams, Zoom, Meet or
/// FaceTime, heard in headphones, where the microphone can't hear them. A Core Audio
/// process tap of everything the Mac plays except Mindtalk ("Inspelning av systemljud",
/// a permission of its own; no screen recording), turned into the meeting's 16 kHz
/// mono and mixed into the microphone's chunks as they come. The microphone's clock
/// leads: the Mac's sound fills in under it, and never runs more than half a second behind.
///
/// Taken only when the sound goes to headphones (by default): through speakers the
/// microphone hears the others already, and both would be the same words twice.
final class CallAudio: @unchecked Sendable {
    static let shared = CallAudio()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "CallAudio")

    /// The Mac's sound a little under the voices in the room: a call comes in loud.
    private static let gain: Float = 0.8

    private struct State {
        var buffer: [Float] = []
        var running = false
        /// When the Mac last played something above a whisper.
        var heardAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "ai.mindact.mindtalk.call-audio", qos: .userInteractive)

    // Set and cleared on the main actor, read on the queue only while the device runs.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    var isRunning: Bool { state.withLock { $0.running } }

    /// Something heard from the Mac in the last few seconds: the call is coming in.
    var hearsSomething: Bool { state.withLock { $0.heardAt.map { Date().timeIntervalSince($0) < 4 } ?? false } }

    // MARK: When

    enum Route: Equatable { case headphones, speakers }

    /// Where the Mac's sound goes now: into headphones (AirPods and other Bluetooth,
    /// the headphone jack, a USB headset) or out into the room.
    static var route: Route {
        guard let output = defaultOutput() else { return .speakers }
        switch uint32(output, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            return .headphones
        case kAudioDeviceTransportTypeBuiltIn:
            // The Mac's own output: its speakers, or headphones in the jack ('hdpn').
            return uint32(output, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) == 0x6864_706E
                ? .headphones : .speakers
        default:
            return .speakers
        }
    }

    /// Whether a meeting should take the Mac's sound now, by the setting and the route.
    @MainActor static var wanted: Bool {
        switch Settings.callAudio {
        case .never: return false
        case .always: return true
        case .headphones: return route == .headphones
        }
    }

    // MARK: Start and stop

    /// The tap on: true when it runs. The first time, macOS asks for the permission;
    /// until it's given (or if it's refused), the tap hears nothing.
    @MainActor @discardableResult
    func start() -> Bool {
        guard tapID == kAudioObjectUnknown else { return true }
        let me = Self.processObject(pid: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        description.name = "Mindtalk"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard Self.ok(AudioHardwareCreateProcessTap(description, &tap), "create the tap") else { return false }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard Self.ok(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "read the tap's format"),
              let input = AVAudioFormat(streamDescription: &format),
              let converter = AVAudioConverter(from: input, to: Recorder.targetFormat) else {
            stop()
            return false
        }
        converter.downmix = true
        inputFormat = input
        self.converter = converter

        // The tap is read through a private device of its own, clocked by the output.
        guard let output = Self.defaultOutput(), let outputUID = Self.uid(output) else { stop(); return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mindtalk",
            kAudioAggregateDeviceUIDKey: "ai.mindact.mindtalk.call.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard Self.ok(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the device") else {
            stop()
            return false
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.received(input)
        }
        guard Self.ok(created, "create the reader"), let proc else { stop(); return false }
        procID = proc
        state.withLock { $0 = State(running: true) }
        guard Self.ok(AudioDeviceStart(device, proc), "start") else { stop(); return false }
        Self.log.notice("call audio on (\(Self.route == .headphones ? "headphones" : "speakers", privacy: .public))")
        return true
    }

    /// The tap off, and everything it made let go. Safe to call when it isn't on.
    @MainActor func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            Self.log.notice("call audio off")
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        converter = nil
        inputFormat = nil
        state.withLock { $0 = State() }
    }

    // MARK: Mixing

    /// The microphone's chunk with the Mac's sound of the same moment laid under it.
    /// Called on the microphone's thread; while the tap is off, the chunk as it was.
    func mixed(_ microphone: [Float]) -> [Float] {
        let call: [Float] = state.withLock { s in
            guard s.running, !s.buffer.isEmpty else { return [] }
            let n = min(microphone.count, s.buffer.count)
            let part = Array(s.buffer.prefix(n))
            s.buffer.removeFirst(n)
            return part
        }
        guard !call.isEmpty else { return microphone }
        var out = microphone
        for i in call.indices {
            out[i] = max(-1, min(1, out[i] + call[i] * Self.gain))
        }
        return out
    }

    /// What the device read: down to 16 kHz mono and onto the end of the buffer.
    private func received(_ list: UnsafePointer<AudioBufferList>) {
        guard let inputFormat, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let ratio = Recorder.targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Recorder.targetFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        // Never "end of stream": the converter keeps its place between reads.
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        let loud = samples.contains { abs($0) > 0.003 }
        state.withLock { s in
            guard s.running else { return }
            s.buffer.append(contentsOf: samples)
            // Behind the microphone by more than half a second (its clock runs slower,
            // or it hasn't started yet): the oldest goes, so the two stay together.
            let most = Int(Recorder.targetFormat.sampleRate) / 2
            if s.buffer.count > most { s.buffer.removeFirst(s.buffer.count - most) }
            if loud { s.heardAt = Date() }
        }
    }

    // MARK: Core Audio

    private static func ok(_ status: OSStatus, _ step: StaticString) -> Bool {
        if status != noErr { log.error("call audio: could not \(step, privacy: .public) (\(status))") }
        return status == noErr
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Mindtalk as Core Audio knows it, to leave its own sounds out of the tap.
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    #if DEBUG
    // MARK: Self-tests

    /// `Mindtalk --call-mix-test`: the mixing alone, with made-up sound (no tap, no
    /// permission): laid under the microphone, never louder than full scale, never more
    /// than half a second behind, and the microphone untouched while it's off.
    static func mixSelfTest() -> Int32 {
        let audio = CallAudio()
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FEL  ") + what); if !ok { failures += 1 } }
        let mic = [Float](repeating: 0.1, count: 1600)
        check(audio.mixed(mic) == mic, "av: mikrofonen som den var")
        audio.state.withLock { $0 = State(buffer: [Float](repeating: 0.5, count: 800), running: true) }
        let out = audio.mixed(mic)
        check(abs(out[0] - (0.1 + 0.5 * gain)) < 0.0001, "på: datorns ljud under mikrofonen")
        check(abs(out[1599] - 0.1) < 0.0001, "för lite från datorn: resten är mikrofonen")
        audio.state.withLock { $0 = State(buffer: [Float](repeating: 1, count: 1600), running: true) }
        check(audio.mixed([Float](repeating: 0.9, count: 1600)).allSatisfy { $0 <= 1 }, "aldrig över fullt utslag")
        // Fed far ahead of the microphone: only the last half second is kept.
        audio.state.withLock { $0 = State(running: true) }
        audio.state.withLock { s in
            s.buffer.append(contentsOf: [Float](repeating: 0.2, count: 16_000 * 3))
            let most = Int(Recorder.targetFormat.sampleRate) / 2
            if s.buffer.count > most { s.buffer.removeFirst(s.buffer.count - most) }
        }
        check(audio.state.withLock { $0.buffer.count } == 8_000, "högst en halv sekund efter")
        _ = CallAudio.route
        print(failures == 0 ? "Call mix self-test passed." : "Call mix self-test: \(failures) FEL")
        return failures == 0 ? 0 : 1
    }

    /// `Mindtalk --call-audio-test`: the real tap. A tone is played on the Mac for two
    /// seconds and must come back through the tap. Asks for the permission the first time.
    @MainActor static func tapSelfTest() async -> Int32 {
        let audio = CallAudio.shared
        guard audio.start() else { print("FEL  tappen kunde inte startas"); return 1 }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        tone.frameLength = 96_000
        for i in 0..<96_000 { tone.floatChannelData![0][i] = 0.2 * sin(2 * .pi * 440 * Float(i) / 48_000) }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { print("FEL  kunde inte spela upp tonen"); audio.stop(); return 1 }
        player.scheduleBuffer(tone, completionHandler: nil)
        player.play()
        var heard: [Float] = []
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            heard += audio.mixed([Float](repeating: 0, count: 1600))
        }
        engine.stop()
        audio.stop()
        let rms = (heard.reduce(0) { $0 + $1 * $1 } / Float(max(1, heard.count))).squareRoot()
        let ok = rms > 0.01
        print(String(format: "%@  tonen hördes genom tappen (RMS %.4f, %d prov, %@)", ok ? "ok " : "FEL", rms, heard.count,
                     route == .headphones ? "hörlurar" : "högtalare"))
        if !ok { print("     Inget hördes: är Inspelning av systemljud tillåten för Mindtalk i Systeminställningar?") }
        return ok ? 0 : 1
    }
    #endif
}

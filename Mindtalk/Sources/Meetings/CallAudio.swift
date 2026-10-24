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

/// The apps that hold calls, by the start of their bundle id: their sound is the call's
/// (CallAudio taps only them), and their using the microphone is a call beginning
/// (CallDetector). Browsers too: Meet and Teams on the web are a page.
enum CallApps {
    static let all: [(prefix: String, name: String, browser: Bool)] = [
        ("us.zoom", "Zoom", false), ("com.microsoft.teams", "Teams", false), ("com.apple.FaceTime", "FaceTime", false),
        ("com.apple.avconferenced", "FaceTime", false), ("com.tinyspeck.slackmacgap", "Slack", false),
        ("com.cisco.webexmeetingsapp", "Webex", false), ("Cisco-Systems.Spark", "Webex", false), ("com.hnc.Discord", "Discord", false),
        ("net.whatsapp.WhatsApp", "WhatsApp", false), ("com.skype.skype", "Skype", false),
        ("com.google.Chrome", "Chrome", true), ("com.apple.Safari", "Safari", true), ("com.apple.WebKit", "Safari", true),
        ("company.thebrowser", "Arc", true), ("org.mozilla.firefox", "Firefox", true), ("com.microsoft.edgemac", "Edge", true),
        ("com.brave.Browser", "Brave", true), ("com.vivaldi.Vivaldi", "Vivaldi", true),
    ]

    static func app(for bundleID: String) -> (prefix: String, name: String, browser: Bool)? {
        all.first { bundleID.hasPrefix($0.prefix) }
    }
}

/// The Mac's own sound, for a meeting on the Mac: the others in Teams, Zoom, Meet or
/// FaceTime, heard in headphones, where the microphone can't hear them. A Core Audio
/// process tap of the call apps playing sound ("Inspelning av systemljud", a permission
/// of its own; no screen recording): not music, not notifications, never Mindtalk. It
/// is turned into the meeting's 16 kHz mono and mixed into the microphone's chunks as
/// they come; the microphone's clock leads, and the Mac's sound never runs more than a
/// fifth of a second behind it.
///
/// Taken only when the sound goes to headphones (by default): through speakers the
/// microphone hears the others already, and both would be the same words twice.
final class CallAudio: @unchecked Sendable {
    static let shared = CallAudio()
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "CallAudio")

    /// The call a little under the voices in the room: it comes in loud.
    private static let gain: Float = 0.7
    /// At most this far behind the microphone (16 kHz samples): a fifth of a second.
    private static let most = 3_200

    private struct State {
        var buffer: [Float] = []
        var running = false
        /// Reads from the device since it started: none at all means it isn't working.
        var reads = 0
        /// When the Mac last played something above a whisper, and whether it ever has.
        var heardAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "ai.mindact.mindtalk.call-audio", qos: .userInteractive)

    /// What a read needs, made per start and held by the reader itself: a read still
    /// under way when the device stops never sees the next start's.
    private final class Reader: @unchecked Sendable {
        let format: AVAudioFormat
        let converter: AVAudioConverter
        /// The tap's buffers at the end of what's read (a device's own come first).
        let buffers: Int
        init(format: AVAudioFormat, converter: AVAudioConverter) {
            self.format = format
            self.converter = converter
            buffers = format.isInterleaved ? 1 : Int(format.channelCount)
        }
    }

    /// How the tap is read: through a private device of the tap alone, or, where that
    /// gives nothing, one clocked by the output device too.
    private enum Variant { case tapOnly, withOutput }

    // On the main actor.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var variant = Variant.tapOnly
    private var startedAt = Date.distantPast
    /// The processes in the running tap, and what it was made for (the output, the format).
    private(set) var processes: Set<AudioObjectID> = []
    private var madeFor: (output: String, rate: Double)?

    var isRunning: Bool { state.withLock { $0.running } }

    /// Something heard from the Mac in the last few seconds: the call is coming in.
    var hearsSomething: Bool { state.withLock { $0.heardAt.map { Date().timeIntervalSince($0) < 4 } ?? false } }
    /// Anything heard since the tap started (not just silence: the permission is given).
    var heardAny: Bool { state.withLock { $0.heardAt != nil } }

    // MARK: When

    enum Route: Equatable { case headphones, speakers }

    /// Where the Mac's sound goes now: into headphones (AirPods and other headsets,
    /// the headphone jack) or out into the room (the Mac's speakers, a display's, a
    /// Bluetooth or USB speaker).
    static var route: Route {
        guard let output = defaultOutput() else { return .speakers }
        if let terminal = outputTerminal(output) {
            switch terminal {
            case kAudioStreamTerminalTypeHeadphones, kAudioStreamTerminalTypeHeadsetMicrophone:
                return .headphones
            case kAudioStreamTerminalTypeSpeaker, kAudioStreamTerminalTypeHDMI, kAudioStreamTerminalTypeDisplayPort,
                 kAudioStreamTerminalTypeLine, kAudioStreamTerminalTypeDigitalAudioInterface:
                return .speakers
            default:
                break
            }
        }
        switch uint32(output, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) {
        case kAudioDeviceTransportTypeBuiltIn:
            // The Mac's own: speakers, or headphones in the jack ('hdpn', or a device of
            // its own on Apple silicon).
            if uint32(output, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) == 0x6864_706E { return .headphones }
            return (uid(output) ?? "").localizedCaseInsensitiveContains("headphone") ? .headphones : .speakers
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            // A headset has a microphone too; a speaker doesn't.
            return hasInput(output) ? .headphones : .speakers
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

    /// The call apps playing sound now, as Core Audio's process objects.
    static func callProcesses() -> Set<AudioObjectID> {
        Set(MediaControl.playingProcesses().filter { CallApps.app(for: $0.bundleID) != nil }.map(\.id))
    }

    /// The tap as it runs no longer fits: another output, its format changed (AirPods
    /// going into headset mode), or a call app it doesn't have has started to play.
    @MainActor func outdated(for playing: Set<AudioObjectID>) -> Bool {
        guard isRunning, let madeFor else { return false }
        if !playing.isSubset(of: processes) { return true }
        guard let output = Self.defaultOutput(), Self.uid(output) == madeFor.output else { return true }
        return Self.tapRate(tapID).map { $0 != madeFor.rate } ?? false
    }

    // MARK: Start and stop

    /// The tap on, for these processes (nil: everything but Mindtalk, for the self-test
    /// everything): true when it runs. The first time, macOS asks for the permission;
    /// until it's given (or if it's refused), the tap hears nothing.
    @MainActor @discardableResult
    func start(processes: Set<AudioObjectID>?, includingMindtalk: Bool = false) -> Bool {
        guard tapID == kAudioObjectUnknown else { return true }
        let description: CATapDescription
        if let processes {
            guard !processes.isEmpty else { return false }
            description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        } else {
            let me = includingMindtalk ? nil : Self.processObject(pid: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: me.map { [$0] } ?? [])
        }
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
              let converter = AVAudioConverter(from: input, to: Recorder.targetFormat),
              let output = Self.defaultOutput(), let outputUID = Self.uid(output) else {
            stop()
            return false
        }
        converter.downmix = true
        let reader = Reader(format: input, converter: converter)

        // The tap alone in a private device: the output's microphone (AirPods) is never
        // opened by it. Clocked by the output as well only where that alone gives nothing.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mindtalk",
            kAudioAggregateDeviceUIDKey: "ai.mindact.mindtalk.call.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if variant == .withOutput {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        guard Self.ok(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the device") else {
            stop()
            return false
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        let created = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, list, _, _, _ in
            self?.received(list, reader)
        }
        guard Self.ok(created, "create the reader"), let proc else { stop(); return false }
        procID = proc
        state.withLock { $0 = State(running: true) }
        guard Self.ok(AudioDeviceStart(device, proc), "start") else { stop(); return false }
        self.processes = processes ?? []
        madeFor = (outputUID, input.sampleRate)
        startedAt = Date()
        Self.log.notice("call audio on: \(processes?.count ?? -1) processes, \(Int(input.sampleRate)) Hz, \(self.variant == .tapOnly ? "tap only" : "with output", privacy: .public)")
        return true
    }

    /// A tap that has read nothing at all in its first seconds: made again, clocked
    /// by the output device this time.
    @MainActor func checkAlive() {
        guard isRunning, variant == .tapOnly, Date().timeIntervalSince(startedAt) > 2.5,
              state.withLock({ $0.reads }) == 0 else { return }
        let processes = self.processes
        Self.log.notice("call audio: nothing read from the tap alone, clocked by the output instead")
        stop()
        variant = .withOutput
        start(processes: processes.isEmpty ? nil : processes)
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
        processes = []
        madeFor = nil
        state.withLock { $0 = State() }
    }

    /// The microphone (re)starting: what waited for it is too old to lay under it.
    func flush() { state.withLock { $0.buffer.removeAll(keepingCapacity: true) } }

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

    /// What the device read: the tap's buffers (at the end of the list), down to 16 kHz
    /// mono and onto the end of the buffer.
    private func received(_ list: UnsafePointer<AudioBufferList>, _ reader: Reader) {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard all.count >= reader.buffers, reader.buffers > 0 else { return }
        let tapOnly = AudioBufferList.allocate(maximumBuffers: reader.buffers)
        defer { free(tapOnly.unsafeMutablePointer) }
        for i in 0..<reader.buffers { tapOnly[i] = all[all.count - reader.buffers + i] }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.format, bufferListNoCopy: tapOnly.unsafePointer, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let ratio = Recorder.targetFormat.sampleRate / reader.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Recorder.targetFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        // Never "end of stream": the converter keeps its place between reads.
        reader.converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return }
        append(Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))))
    }

    /// Onto the end of what waits for the microphone, never more than a fifth of a
    /// second of it (the microphone's clock runs slower, or it hasn't started yet).
    private func append(_ samples: [Float]) {
        let loud = samples.contains { abs($0) > 0.003 }
        state.withLock { s in
            guard s.running else { return }
            s.reads += 1
            s.buffer.append(contentsOf: samples)
            if s.buffer.count > Self.most { s.buffer.removeFirst(s.buffer.count - Self.most) }
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

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) -> UInt32? {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address),
              AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func streams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ device: AudioDeviceID) -> Bool { !streams(device, scope: kAudioDevicePropertyScopeInput).isEmpty }

    /// What the output's first stream says it plays into (headphones, a speaker, HDMI…); nil when it doesn't say.
    private static func outputTerminal(_ device: AudioDeviceID) -> UInt32? {
        guard let stream = streams(device, scope: kAudioDevicePropertyScopeOutput).first,
              let terminal = uint32(stream, kAudioStreamPropertyTerminalType, scope: kAudioObjectPropertyScopeGlobal),
              terminal != 0 else { return nil }
        return terminal
    }

    private static func tapRate(_ tap: AudioObjectID) -> Double? {
        guard tap != kAudioObjectUnknown else { return nil }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format.mSampleRate
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
    /// than a fifth of a second behind, and the microphone untouched while it's off.
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
        // Fed far ahead of the microphone: only the last fifth of a second is kept.
        audio.state.withLock { $0 = State(running: true) }
        for _ in 0..<30 { audio.append([Float](repeating: 0.2, count: 1_600)) }
        check(audio.state.withLock { $0.buffer.count } == most, "högst en femtedels sekund efter")
        audio.flush()
        check(audio.state.withLock { $0.buffer.isEmpty }, "mikrofonen startar om: det gamla släpps")
        _ = CallAudio.route
        print(failures == 0 ? "Call mix self-test passed." : "Call mix self-test: \(failures) FEL")
        return failures == 0 ? 0 : 1
    }

    /// `Mindtalk --call-audio-test`: the real tap. A tone is played on the Mac for two
    /// seconds and must come back through the tap. Asks for the permission the first time.
    @MainActor static func tapSelfTest() async -> Int32 {
        let audio = CallAudio.shared
        // Everything, Mindtalk too: the tone is Mindtalk's own.
        guard audio.start(processes: nil, includingMindtalk: true) else { print("FEL  tappen kunde inte startas"); return 1 }
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

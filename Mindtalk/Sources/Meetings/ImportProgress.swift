import SwiftUI

// MARK: - A file being made into a meeting, in the drop zone
//
// The zone "Har du redan en inspelning?" is where a dropped file is worked on, start to
// end, with nothing under it: the file's name, then points that gather, lie down as a
// wave of sound filled from the left as the text is written, part into the voices,
// gather into lines while the summary is written, and give way to the meeting's title,
// its voices and Öppna. A while after, the zone is the zone again.

struct ImportProgress: View {
    let job: MeetingImport.Job
    /// Files behind it in the queue.
    let waiting: Int
    /// Beside the start card, as large as it; otherwise the strip under it.
    var tall = true
    @ObservedObject private var notes = MeetingNotes.shared
    @ObservedObject private var store = MeetingStore.shared

    private var failed: Bool { job.stage == .failed }
    private var record: MeetingRecord? { job.meeting.flatMap { id in store.meetings.first { $0.id == id } } }
    private var summarizing: Bool { job.stage == .done && job.meeting.map { notes.writing.contains($0) } == true }

    var body: some View {
        Group {
            if tall {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    ImportDots(mode: mode, fill: fill)
                        .frame(height: job.stage == .done && !summarizing ? 56 : 120)
                        .frame(maxWidth: 360)
                        .padding(.bottom, 8)
                    title
                    if job.stage == .done, !summarizing, let record { voices(record) }
                    Text(verbatim: status)
                        .font(.system(size: 13)).foregroundStyle(failed ? DS.Colors.warning : DS.Colors.muted)
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                    actions.padding(.top, 8)
                    if waiting > 0 { queueLine.padding(.top, 2) }
                    Spacer(minLength: 0)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 14) {
                    ImportDots(mode: mode, fill: fill, small: true)
                        .frame(width: 120, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: shownTitle)
                            .font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: status + (waiting > 0 ? " · " + queueText : ""))
                            .font(.system(size: 12.5)).foregroundStyle(failed ? DS.Colors.warning : DS.Colors.muted)
                            .monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(minHeight: 66)
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.12), value: job.stage)
        .animation(.easeOut(duration: 0.3), value: summarizing)
        .onHover { inside in if inside { MeetingImport.shared.touch(job.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityValue(job.active ? String(localized: "\(Int(job.progress * 100)) procent") : "")
    }

    /// The points' picture for where the job is, and how far that step has come.
    private var mode: ImportDots.Mode {
        switch job.stage {
        case .waiting, .reading: return .gather
        case .writing: return .wave
        case .voices: return .voices
        case .done: return summarizing ? .summary : .rest
        case .failed: return .failed
        }
    }

    private var fill: Double {
        let stage = job.stage
        guard stage == .reading || stage == .writing || stage == .voices else { return 1 }
        return min(1, max(0, (job.progress - stage.start) / max(0.01, stage.end - stage.start)))
    }

    private var shownTitle: String { failed ? job.url.lastPathComponent : (record?.title ?? job.title ?? job.name) }

    @ViewBuilder private var title: some View {
        if job.stage == .done {
            Text(verbatim: shownTitle)
                .font(.system(size: 22, design: .serif))
                .multilineTextAlignment(.center).lineLimit(2)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            Text(verbatim: shownTitle)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
        }
    }

    /// The voices it found, as their figures: what Mindtalk does best, shown at the end.
    @ViewBuilder private func voices(_ record: MeetingRecord) -> some View {
        let cast = record.cast
        if !cast.order.isEmpty {
            HStack(spacing: 4) {
                ForEach(cast.order.prefix(6), id: \.self) { speaker in
                    let name = cast.names[String(speaker)].flatMap { $0.isEmpty ? nil : $0 }
                    VoiceFigureView(figure: name.flatMap(VoiceFigure.remembered) ?? VoiceFigure.from(seed: name ?? "\(record.id)-\(speaker)"),
                                    color: SpeakerMark.color(of: speaker, in: cast), size: .compact, diameter: 28, tinted: true)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var status: String {
        switch job.stage {
        case .failed: return job.error ?? String(localized: "Filen kunde inte läsas.")
        case .waiting: return job.stage.title
        case .reading, .writing: return job.stage.title + " · \(Int((fill * 100).rounded())) %"
        case .voices: return job.stage.title
        case .done:
            if summarizing { return String(localized: "Skriver sammanfattningen") }
            guard let record else { return job.stage.title }
            let speakers = record.cast.order.count
            let when = record.source?.dateKnown == false ? String(localized: "Datum okänt")
                                                         : String(localized: "Inspelad \(MeetingRecord.day(record.date, long: true))")
            return speakers > 0 ? when + " · " + (speakers == 1 ? String(localized: "1 talare") : String(localized: "\(speakers) talare")) : when
        }
    }

    private var queueText: String {
        waiting == 1 ? String(localized: "1 fil till väntar") : String(localized: "\(waiting) filer till väntar")
    }

    private var queueLine: some View {
        Text(verbatim: queueText).font(.system(size: 12)).foregroundStyle(DS.Colors.faint)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch job.stage {
            case .done:
                if let id = job.meeting {
                    Button("Öppna") {
                        MeetingsPage.lastOpen = id
                        NotificationCenter.default.post(name: .openMeeting, object: id)
                        MeetingImport.shared.remove(job.id)
                    }
                    .buttonStyle(.ink)
                }
                Button("Stäng") { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } }
                    .buttonStyle(SoftButtonStyle(small: !tall))
            case .failed:
                Button("Stäng") { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } }
                    .buttonStyle(SoftButtonStyle(small: !tall))
            case .waiting:
                languageMenu
                Button("Ta bort ur kön") { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } }
                    .buttonStyle(SoftButtonStyle(small: true))
            default:
                Button("Avbryt") { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } }
                    .buttonStyle(SoftButtonStyle(small: true))
                    .help("Avbryt så skrivs filen inte ned")
            }
        }
        .fixedSize()
    }

    /// While it waits: the language it'll be heard in, when there's more than one.
    @ViewBuilder private var languageMenu: some View {
        let models = SpeechModel.allCases.filter(\.isInstalled)
        if models.count > 1 {
            Menu {
                ForEach(models, id: \.self) { model in
                    Button {
                        MeetingImport.shared.setLanguage(model, for: job.id)
                    } label: {
                        if model == job.language { Label(model.spokenIn, systemImage: "checkmark") } else { Text(model.spokenIn) }
                    }
                }
            } label: {
                Label(job.language.spokenIn, systemImage: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Colors.muted)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Språket i filen")
        }
    }
}

// MARK: - The points

/// Two hundred points in ink that tell what the file is going through: scattered as it
/// lands, gathered while it's read, a wave of sound filled from the left as the text is
/// written, the wave parting into voices (in their colours), lines while the summary is
/// written, a quiet line at rest. Each change eases over a second, each point a little
/// after the last. Still with Reduce Motion.
struct ImportDots: View {
    enum Mode: Equatable { case scatter, gather, wave, voices, summary, rest, failed }
    let mode: Mode
    /// How far the step has come, 0…1: the wave fills, the voices take their colours.
    let fill: Double
    /// The strip's (34 pt high): fewer, finer points.
    var small = false
    @State private var shift = Shift()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the points are coming from and going to. A class, so the drawing can read
    /// and ease it every frame without redrawing the view.
    final class Shift {
        var from: Mode = .scatter
        var to: Mode = .gather
        var at = Date.timeIntervalSinceReferenceDate
        var shownFill = 0.0
        var lastFrame: Double?
    }

    private struct Point { let u: Double; let a: Double; let b: Double }
    private static let points: [Point] = {
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        return (0..<200).map { i in Point(u: (Double(i) + next()) / 200, a: next(), b: next()) }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            Canvas { g, size in draw(&g, size: size, now: now) }
        }
        .onAppear {
            // Landing: from scattered over the zone into the cloud. Shown later in a
            // job's life (the page opened mid-way), straight in its place.
            shift.from = mode == .gather ? .scatter : mode
            shift.to = mode
            shift.at = Date.timeIntervalSinceReferenceDate
            shift.shownFill = fill
        }
        .onChange(of: mode) { old, new in
            shift.from = old
            shift.to = new
            shift.at = Date.timeIntervalSinceReferenceDate
        }
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, now: Double) {
        // The fill follows the job smoothly, never jumping with a step's estimate.
        let dt = shift.lastFrame.map { min(0.2, max(0, now - $0)) } ?? 0
        shift.lastFrame = now
        shift.shownFill += (fill - shift.shownFill) * (reduceMotion ? 1 : min(1, dt * 3))
        let t = reduceMotion ? 0 : now.truncatingRemainder(dividingBy: 10_000)
        let k = reduceMotion ? 1 : min(1, max(0, (now - shift.at) / 1.0))
        let step = small ? 2 : 1
        for (i, p) in Self.points.enumerated() where i % step == 0 {
            // Each point a little after the last, so the change flows rather than snaps.
            let ki = min(1, max(0, k * 1.5 - p.a * 0.5)), e = ki * ki * (3 - 2 * ki)
            let from = place(shift.from, p, i, size, t)
            let to = place(shift.to, p, i, size, t)
            let x = from.x + (to.x - from.x) * e, y = from.y + (to.y - from.y) * e
            let alpha = from.alpha + (to.alpha - from.alpha) * e
            let r = (from.r + (to.r - from.r) * e) * (small ? 0.75 : 1)
            let tint = e > 0.5 ? to.tint : from.tint
            let colour = tint.map { SpeakerMark.fill($0) } ?? DS.Colors.ink
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                   with: .color(colour.opacity(alpha)))
        }
    }

    private struct Placed { var x: Double; var y: Double; var alpha: Double; var r: Double; var tint: Int? }

    private func place(_ mode: Mode, _ p: Point, _ i: Int, _ size: CGSize, _ t: Double) -> Placed {
        let w = Double(size.width), h = Double(size.height)
        let cx = w / 2, cy = h / 2
        let left = w * 0.04, span = w * 0.92
        switch mode {
        case .scatter:
            return Placed(x: p.a * w, y: p.b * h, alpha: 0.08, r: 1.0, tint: nil)
        case .gather:
            // A small turning sphere, as on the start card: the points spread evenly
            // over it, the near ones darker and larger.
            let R = min(w, h) * 0.44
            let y = 1 - 2 * p.u, ring = (1 - y * y).squareRoot()
            let angle = Double(i) * 2.399963 + t * 0.5
            let x3 = cos(angle) * ring, z3 = sin(angle) * ring
            let (ct, st) = (cos(0.4), sin(0.4))
            let y2 = y * ct - z3 * st, near = (y * st + z3 * ct + 1) / 2
            return Placed(x: cx + x3 * R, y: cy + y2 * R, alpha: 0.12 + 0.75 * near, r: 0.7 + 1.0 * near, tint: nil)
        case .wave, .voices:
            let filled = mode == .voices || p.u <= shift.shownFill
            let x = left + p.u * span
            let envelope = 0.3 + 0.7 * abs(sin(p.u * 9 + t * 1.2) * sin(p.u * 3.1 - t * 0.6))
            let spread = (p.a - 0.5) * 2
            let amplitude = filled ? h * 0.44 * envelope : h * 0.035
            let near = 1 - abs(spread)
            // The voices: the wave parts into stretches, each a voice's colour, from the left.
            let tint: Int? = mode == .voices && p.u <= shift.shownFill
                ? Int((p.u * 5 + 0.35 * sin(p.u * 23)).rounded(.down)) % 3 : nil
            return Placed(x: x, y: cy + spread * amplitude, alpha: filled ? 0.3 + 0.6 * near : 0.14,
                          r: filled ? 0.9 + 0.7 * near : 0.8, tint: tint)
        case .summary:
            // Lines being written: a light runs along them, left to right.
            let lines = [0.94, 0.8, 0.88, 0.52]
            let line = i % lines.count
            let x = w * 0.08 + p.u * w * 0.84 * lines[line]
            let y = cy + (Double(line) - 1.5) * h * 0.18 + (p.b - 0.5) * 3
            let sweep = (t * 0.32).truncatingRemainder(dividingBy: 1.3) - 0.15
            let lit = max(0, 1 - abs(p.u - sweep) * 5)
            return Placed(x: x, y: y, alpha: 0.22 + 0.6 * lit, r: 1.0 + 0.4 * lit, tint: nil)
        case .rest:
            return Placed(x: left + p.u * span, y: cy + (p.b - 0.5) * 4, alpha: 0.16, r: 0.85, tint: nil)
        case .failed:
            return Placed(x: left + p.u * span, y: h * 0.82 + (p.b - 0.5) * 6, alpha: 0.12, r: 0.85, tint: nil)
        }
    }
}

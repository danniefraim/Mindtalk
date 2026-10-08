import SwiftUI

// MARK: - The meeting's fingerprint
//
// Who spoke when, as one strip: a lane per speaker, their turns drawn in their
// quiet colour — a monologue, a ping-pong, a four-way debate each look their own.
// Decisions (diamonds) and tasks (rings) sit above it where they were said, and
// the moments you marked as small flags in the accent colour. Point
// at it to see who spoke then; click or drag to listen from there. In the list, a
// small one tells meetings apart at a glance.

struct MeetingRibbon: View {
    let record: MeetingRecord
    let cast: Cast
    let segments: [MeetingText.Segment]
    var compact = false
    /// Recording: grows as the meeting does, nothing to play yet.
    var live = false
    /// Recording: how far it has come (seconds) — a line where "now" is.
    var now: Double? = nil
    @ObservedObject private var player = MeetingPlayer.shared
    @State private var hover: CGFloat?

    private var duration: Double {
        let heard = max(record.duration, segments.last?.end ?? 0, record.words.last?.end ?? 0, 1)
        guard live else { return heard }
        // Recording: a horizon that steps out now and then (2, 5, 10 … minutes) — the
        // strip fills towards it, rather than everything squeezing left at every word.
        return Self.horizons.first { $0 >= heard * 1.1 } ?? heard * 1.25
    }
    private static let horizons: [Double] = [2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240].map { $0 * 60 }
    private var lanes: Int { max(1, cast.order.count) }
    private var laneHeight: CGFloat { compact ? max(2, (18 - CGFloat(lanes - 1) * 1.5) / CGFloat(lanes)) : 5 }
    private var laneGap: CGFloat { compact ? 1.5 : 3 }
    private var markerRow: CGFloat { compact ? 0 : 12 }
    private var height: CGFloat { markerRow + CGFloat(lanes) * (laneHeight + laneGap) - laneGap }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size) }
                .overlay(alignment: .topLeading) { if !compact { hoverLabel(width: geo.size.width) } }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !compact, !live, record.hasAudio else { return }
                    if case .active(let p) = phase { hover = p.x } else { hover = nil }
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    guard !compact, !live, record.hasAudio else { return }
                    let t = max(0, min(1, v.location.x / geo.size.width)) * duration
                    if player.meeting == record.id { player.seek(to: t) } else { player.play(record.id, from: t) }
                })
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tidslinje: vem pratade när")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let x = { (t: Double) in CGFloat(t / duration) * w }
        // Lanes, then each speaker's turns on theirs.
        for lane in 0..<lanes {
            let y = markerRow + CGFloat(lane) * (laneHeight + laneGap)
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: w, height: laneHeight), cornerRadius: laneHeight / 2),
                     with: .color(DS.Colors.chip.opacity(compact ? 0.8 : 0.6)))
        }
        for s in segments {
            guard let lane = cast.order.firstIndex(of: s.speaker) else { continue }
            let y = markerRow + CGFloat(lane) * (laneHeight + laneGap)
            let rect = CGRect(x: x(s.start), y: y, width: max(compact ? 1.5 : 2.5, x(s.end) - x(s.start)), height: laneHeight)
            ctx.fill(Path(roundedRect: rect, cornerRadius: laneHeight / 2),
                     with: .color(SpeakerMark.color(of: s.speaker, in: cast)))
        }
        // Recording: now, with the empty strip to its right still to come.
        if live, let now, !compact {
            let nx = min(w - 1, x(now))
            ctx.fill(Path(roundedRect: CGRect(x: nx - 0.75, y: markerRow - 3, width: 1.5, height: size.height - markerRow + 3),
                          cornerRadius: 0.75), with: .color(DS.Colors.ink.opacity(0.75)))
            ctx.fill(Path(ellipseIn: CGRect(x: nx - 2.5, y: markerRow - 6, width: 5, height: 5)), with: .color(DS.Colors.recording))
        }
        guard !compact else { return }
        // Where decisions and tasks were said.
        if let summary = record.summary {
            for item in summary.decisions { if let at = item.at { diamond(&ctx, x(at)) } }
            for item in summary.tasks { if let at = item.at { ring(&ctx, x(at)) } }
        }
        // The moments you marked.
        for mark in record.marks { flag(&ctx, x(mark.at), mark.kind.tint) }
        // Listening: where you are.
        if player.meeting == record.id {
            let px = x(player.time)
            ctx.fill(Path(roundedRect: CGRect(x: px - 0.75, y: markerRow - 3, width: 1.5, height: size.height - markerRow + 3),
                          cornerRadius: 0.75), with: .color(DS.Colors.ink))
        }
        if let hover {
            ctx.fill(Path(CGRect(x: hover - 0.5, y: markerRow - 3, width: 1, height: size.height - markerRow + 3)),
                     with: .color(DS.Colors.muted.opacity(0.6)))
        }
    }

    private func diamond(_ ctx: inout GraphicsContext, _ x: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: x, y: 1)); p.addLine(to: CGPoint(x: x + 3.5, y: 4.5))
        p.addLine(to: CGPoint(x: x, y: 8)); p.addLine(to: CGPoint(x: x - 3.5, y: 4.5)); p.closeSubpath()
        ctx.fill(p, with: .color(DS.Colors.ink))
    }

    private func flag(_ ctx: inout GraphicsContext, _ x: CGFloat, _ tint: Color) {
        ctx.fill(Path(roundedRect: CGRect(x: x - 0.6, y: 0, width: 1.2, height: 9), cornerRadius: 0.6), with: .color(tint))
        var p = Path()
        p.move(to: CGPoint(x: x + 0.6, y: 0)); p.addLine(to: CGPoint(x: x + 5.5, y: 2.2)); p.addLine(to: CGPoint(x: x + 0.6, y: 4.4))
        p.closeSubpath()
        ctx.fill(p, with: .color(tint))
    }

    private func ring(_ ctx: inout GraphicsContext, _ x: CGFloat) {
        ctx.stroke(Path(ellipseIn: CGRect(x: x - 3.5, y: 1, width: 7, height: 7)), with: .color(DS.Colors.ink), lineWidth: 1.4)
    }

    /// "Anna · 3:12" over the strip where you point.
    @ViewBuilder private func hoverLabel(width: CGFloat) -> some View {
        if let hover {
            let t = Double(hover / width) * duration
            let who = segments.last { $0.start <= t + 0.3 }.flatMap { $0.end + 1.5 >= t ? cast.name(of: $0.speaker) : nil }
            Text([who, MeetingView.duration(t)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(DS.Colors.onInk)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.Colors.ink))
                .fixedSize()
                .offset(x: min(max(0, hover - 40), width - 110), y: -26)
                .allowsHitTesting(false)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Dropping a file on the Möten page

extension View {
    /// Sound or video dropped anywhere on the page: imported — into the folder chosen.
    func importDrop() -> some View { modifier(ImportDrop()) }
}

private struct ImportDrop: ViewModifier {
    @State private var targeted = false
    @ObservedObject private var folders = MeetingFolders.shared
    @ObservedObject private var session = MeetingSession.shared
    @ObservedObject private var importer = MeetingImport.shared

    func body(content: Content) -> some View {
        content
            .overlay {
                // With the start card on screen, its zone lights up instead (StartCard).
                if targeted && !importer.zoneVisible {
                    DropSign(folder: folders.folder(folders.selected)?.name, later: session.isBusy,
                             missing: !MeetingImport.shared.ready)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: targeted)
            .modifier(DropTarget(targeted: $targeted) { providers in importer.take(providers, folder: folders.selected) })
            .onChange(of: targeted) { _, now in importer.pageDragging = now }
    }
}

/// Takes sound and video dropped on the view — except in a still picture of the page,
/// where a drop target draws as a sign.
private struct DropTarget: ViewModifier {
    @Binding var targeted: Bool
    let take: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        #if DEBUG
        if Demo.rendering { return AnyView(content) }
        #endif
        return AnyView(content.onDrop(of: [.fileURL, .audiovisualContent], isTargeted: $targeted) { take($0) })
    }
}

/// "Släpp så skrivs den ned": the page dims, a frame lights up and slowly turns.
struct DropSign: View {
    let folder: String?
    /// A meeting is being recorded: it waits until that's done.
    var later = false
    /// The speech model or the voices aren't downloaded yet.
    var missing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DS.Colors.paper.opacity(0.88)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                let turn = (context.date.timeIntervalSinceReferenceDate / 6).truncatingRemainder(dividingBy: 1) * 360
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(AngularGradient(colors: [DS.Colors.accentSoft, DS.Colors.accent, DS.Colors.accentSoft],
                                                  center: .center, angle: .degrees(turn)),
                                  style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                    .padding(28)
            }
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(DS.Colors.chip).frame(width: 84, height: 84)
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Colors.ink)
                        .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !reduceMotion)
                }
                Text("Släpp så skrivs den ned")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(missing ? DS.Colors.warning : DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
        }
    }

    private var subtitle: String {
        if missing { return String(localized: "Ladda ned talmodellen och Nemotron 3 först, under Inställningar → Modeller.") }
        if later { return String(localized: "Ljud eller video. Filen skrivs ned när mötet är slut.") }
        if let folder { return String(localized: "Ljud eller video. Mötet hamnar i \(folder).") }
        return String(localized: "Ljud eller video. Du ser vem som sa vad, får en sammanfattning och kan ställa frågor om innehållet.")
    }
}

// MARK: - The files being imported

/// A card per file: what it's doing, how far it is — then "Öppna". Gone by itself a
/// while after it's done.
struct ImportCards: View {
    @ObservedObject private var importer = MeetingImport.shared
    var compact = false
    let open: (UUID) -> Void

    var body: some View {
        if !importer.jobs.isEmpty || importer.refused != nil {
            VStack(spacing: 10) {
                if let refused = importer.refused {
                    Label(refused, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.Colors.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                ForEach(importer.jobs) { job in
                    ImportCard(job: job, compact: compact, open: open)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: importer.jobs.map(\.id))
            .animation(.easeOut(duration: 0.25), value: importer.refused)
        }
    }
}

struct ImportCard: View {
    let job: MeetingImport.Job
    var compact = false
    let open: (UUID) -> Void
    @ObservedObject private var notes = MeetingNotes.shared

    private var done: Bool { job.stage == .done }
    private var failed: Bool { job.stage == .failed }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(DS.Colors.chip).frame(width: 46, height: 46)
                if job.active {
                    Circle().trim(from: 0, to: max(0.02, job.progress))
                        .stroke(DS.Gradients.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 46, height: 46)
                        .animation(.easeOut(duration: 0.4), value: job.progress)
                }
                Image(systemName: failed ? "exclamationmark.triangle.fill" : done ? "checkmark" : job.video ? "film" : "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(failed ? DS.Colors.warning : done ? DS.Colors.good : DS.Colors.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(failed ? job.url.lastPathComponent : (job.title ?? job.name))
                    .font(.system(size: 14.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                status
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(job.active ? String(localized: "\(Int(job.progress * 100)) procent") : "")
            Spacer(minLength: 12)
            if job.stage == .waiting { languageMenu }
            if done, let id = job.meeting {
                Button("Öppna") {
                    open(id)
                    MeetingImport.shared.remove(job.id)
                }
                .buttonStyle(.ink)
            }
            Button { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } } label: {
                Image(systemName: job.active ? "stop.fill" : "xmark")
                    .font(.system(size: job.active ? 9 : 10, weight: .bold)).foregroundStyle(DS.Colors.muted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(job.active ? "Avbryt så skrivs filen inte ned" : job.stage == .waiting ? "Ta bort ur kön" : "Stäng")
            .accessibilityLabel(job.active ? "Avbryt" : job.stage == .waiting ? "Ta bort ur kön" : "Stäng")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 10 : 12)
        .raised(cornerRadius: DS.Radius.card)
        .onHover { inside in if inside { MeetingImport.shared.touch(job.id) } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        if failed {
            Text(job.error ?? "").font(.system(size: 12.5)).foregroundStyle(DS.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if done {
            Text(doneText).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
        } else {
            HStack(spacing: 8) {
                // The percent where it's real (reading the file); the step's name elsewhere.
                Text(job.stage.title
                     + (job.stage == .reading ? " · \(Int(job.progress / MeetingImport.Stage.reading.end * 100)) %" : "")
                     // (Waiting, the language has its own menu beside it.)
                     + (job.stage == .waiting && SpeechModel.allCases.filter(\.isInstalled).count > 1
                        ? "" : " · " + job.language.spokenIn.lowercased()))
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 4) {
                    ForEach(MeetingImport.Stage.steps, id: \.self) { step in
                        Capsule()
                            .fill(step.index <= job.stage.index ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.chip))
                            .frame(width: step == job.stage ? 16 : 6, height: 6)
                    }
                }
                .accessibilityHidden(true)
                .animation(.spring(duration: 0.4, bounce: 0.2), value: job.stage)
            }
        }
    }

    private var doneText: String {
        guard let id = job.meeting else { return String(localized: "Klar") }
        if notes.writing.contains(id) { return String(localized: "Klar. Sammanfattningen skrivs…") }
        return MeetingNotes.isAvailable ? String(localized: "Klar: text, talare och sammanfattning")
                                        : String(localized: "Klar: text och talare")
    }

    /// While it waits: the language it'll be heard in.
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

// MARK: - A meeting's date

/// "Ändra datum…": when it really was — for a file whose own date was wrong.
struct MeetingDateSheet: View {
    let record: MeetingRecord
    let done: () -> Void
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("När var mötet?").font(.system(size: 15, weight: .semibold))
            DatePicker("", selection: $date, in: ...Date())
                .datePickerStyle(.graphical)
                .labelsHidden()
            if let source = record.source {
                Text("Importerad \(MeetingRecord.when(source.importedAt).prefix(1).lowercased() + MeetingRecord.when(source.importedAt).dropFirst()) från \(source.file)")
                    .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
            }
            HStack {
                Spacer()
                Button("Avbryt", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Spara") {
                    MeetingStore.shared.setDate(date, of: record.id)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 320)
        .onAppear { date = record.date }
    }
}

// MARK: - Saying you can

/// Under an empty archive: a recording you already have can come in too.
struct ImportHint: View {
    @State private var hovering = false

    var body: some View {
        Button { MeetingImport.shared.choose(folder: MeetingFolders.shared.selected) } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down")
                Text("Har du redan en inspelning? Dra hit den, eller välj en fil")
                Text(verbatim: "⌘O").foregroundStyle(DS.Colors.faint)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hovering ? DS.Colors.ink : DS.Colors.muted)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .overlay(Capsule().strokeBorder(DS.Colors.muted.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Where it came from

/// "importerad från Khraftpodden #197.mp3" beside a meeting's date — click to see the
/// file in Finder: where it was saved, where it was moved to since, or — imported
/// before the place was kept — wherever Spotlight finds a file of that name.
struct SourceLink: View {
    let source: MeetingRecord.Source
    @State private var hovering = false
    @State private var missing = false

    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 4) {
                Text(verbatim: "·")
                Text("importerad från")
                Text(source.file)
                    .underline(hovering)
                    .foregroundStyle(hovering ? DS.Colors.ink : DS.Colors.muted)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: missing ? "questionmark.folder" : "arrow.up.forward.square")
                    .font(.system(size: 10.5, weight: .semibold))
                    .opacity(hovering || missing ? 1 : 0.6)
            }
            .font(.system(size: 13))
            .foregroundStyle(DS.Colors.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(missing ? "Filen hittades inte. Den kan ha tagits bort" : "Visa filen i Finder")
        .accessibilityLabel("Importerad från \(source.file). Visa filen i Finder")
    }

    private func reveal() {
        Task { @MainActor in
            if let url = await Self.locate(source) {
                missing = false
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                withAnimation(.snappy) { missing = true }
                NSSound.beep()
            }
        }
    }

    /// The bookmark (follows a move or a rename), the path, then Spotlight by name.
    nonisolated static func locate(_ source: MeetingRecord.Source) async -> URL? {
        let fm = FileManager.default
        if let data = source.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) { return url }
        }
        if let path = source.path, fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        // Imported before the place was kept: a file of that name, the newest one — or,
        // a download's copy ("Podd (1).mp3") gone, the one it was a copy of.
        if let found = await spotlight(source.file) { return found }
        let plain = source.file.replacingOccurrences(of: #" \(\d+\)(?=\.[^.]+$)"#, with: "", options: .regularExpression)
        return plain == source.file ? nil : await spotlight(plain)
    }

    nonisolated private static func spotlight(_ file: String) async -> URL? {
        let fm = FileManager.default
        let name = file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemFSName == \"\(name)\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let out = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let found = String(decoding: out, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { !$0.path.contains("/Library/Application Support/Mindtalk/") && fm.fileExists(atPath: $0.path) }
        return found.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }
}


// MARK: - The start card's two ways in

/// Record: the ink disc with the red dot.
struct RecordGlyph: View {
    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.ink)
            Circle().fill(DS.Colors.recording).frame(width: 10, height: 10)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// A dashed place to drop a recording, at the foot of the start card: the whole of it
/// also opens a file, and "Välj fil…" is there for those who'd rather choose.
struct ImportZone: View {
    let folder: UUID?
    /// One row (under the ways in), rather than a block.
    var compact = false
    @ObservedObject private var importer = MeetingImport.shared
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        let dropping = importer.dropping
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            shape.fill(DS.Colors.chip.opacity(dropping ? 0.7 : hovering ? 0.45 : 0))
            shape.strokeBorder(dropping ? DS.Colors.ink : DS.Colors.fieldStroke.opacity(hovering ? 1 : 0.8),
                               style: dropping ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1, dash: [5, 4]))
            content(dropping)
                .padding(.horizontal, compact ? 14 : 18)
                .padding(.vertical, compact ? 10 : 18)
                .foregroundStyle(.primary)
        }
        .contentShape(shape)
        .onTapGesture { importer.choose(folder: folder) }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .modifier(DropTarget(targeted: $targeted) { providers in importer.take(providers, folder: folder) })
        .onChange(of: targeted) { _, now in importer.zoneTargeted = now }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: dropping)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dra hit en inspelning, eller välj en fil")
    }

    @ViewBuilder private func content(_ dropping: Bool) -> some View {
        if compact {
            HStack(spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 2) {
                    Text(dropping ? "Släpp så skrivs den ned" : "Dra hit en inspelning")
                        .font(.system(size: 13.5, weight: .semibold))
                    if !dropping {
                        Text("Ljud eller video, till exempel mp3, m4a eller mp4").font(.system(size: 12))
                            .foregroundStyle(DS.Colors.muted)
                    }
                }
                Spacer(minLength: 8)
                if !dropping { chooseButton }
            }
        } else {
            VStack(spacing: 10) {
                glyph
                if dropping {
                    Text("Släpp så skrivs den ned").font(.system(size: 20, design: .serif))
                } else {
                    VStack(spacing: 3) {
                        Text("Dra hit en inspelning").font(.system(size: 15, weight: .semibold))
                        Text("Ljud eller video, till exempel mp3, m4a eller mp4").font(.system(size: 13))
                            .foregroundStyle(DS.Colors.muted)
                    }
                    chooseButton.padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
        }
    }

    private var glyph: some View {
        ZStack {
            Circle().fill(DS.Colors.chip)
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: compact ? 15 : 18, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Colors.ink)
        }
        .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
        .accessibilityHidden(true)
    }

    private var chooseButton: some View {
        HStack(spacing: 8) {
            Button("Välj fil…") { importer.choose(folder: folder) }
                .buttonStyle(.soft)
                .help("Välj en ljud- eller videofil (⌘O)")
            KeyChip(text: "⌘O", small: true)
        }
    }
}

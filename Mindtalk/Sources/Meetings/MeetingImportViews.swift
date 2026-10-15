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

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    DropSign(folder: folders.folder(folders.selected)?.name, later: session.isBusy,
                             missing: !MeetingImport.shared.ready)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: targeted)
            // Files from Finder, and copies handed over by apps (Röstmemon, Bilder).
            .onDrop(of: [.fileURL, .audiovisualContent], isTargeted: $targeted) { providers in
                let folder = folders.selected
                var any = false
                for provider in providers {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        any = true
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url, url.isFileURL else { return }
                            Task { @MainActor in MeetingImport.shared.add([url], folder: folder) }
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.audiovisualContent.identifier) {
                        any = true
                        MeetingImport.shared.addCopy(of: provider, folder: folder)
                    }
                }
                return any
            }
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
        if missing { return String(localized: "Ladda ned talmodellen och Nemotron 3 först – på sidan Möten.") }
        if later { return String(localized: "Ljud eller video – den skrivs ned när mötet är slut.") }
        if let folder { return String(localized: "Ljud eller video – texten, rösterna och anteckningarna hamnar i \(folder).") }
        return String(localized: "Ljud eller video – du får texten med vem som sa vad, anteckningar och kan fråga om innehållet.")
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
            .help(job.active ? "Avbryt – filen skrivs inte ned" : job.stage == .waiting ? "Ta bort ur kön" : "Stäng")
            .accessibilityLabel(job.active ? "Avbryt" : job.stage == .waiting ? "Ta bort ur kön" : "Stäng")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 10 : 12)
        .raised(cornerRadius: 18)
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
        if notes.writing.contains(id) { return String(localized: "Klar – anteckningarna skrivs…") }
        return MeetingNotes.isAvailable ? String(localized: "Klar – texten, rösterna och anteckningarna")
                                        : String(localized: "Klar – texten och rösterna")
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
                Text("Importerad \(MeetingRecord.when(source.importedAt)) från \(source.file)")
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
                Text("Har du redan en inspelning? Dra in den här, eller välj en fil")
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

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

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    DropSign(folder: folders.folder(folders.selected)?.name)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.15), value: targeted)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                MeetingImport.shared.add(files, folder: folders.selected)
                return true
            } isTargeted: { targeted = $0 }
    }
}

/// "Släpp för att skriva ut": the page dims, a frame lights up with the app's
/// gradient, slowly turning.
struct DropSign: View {
    let folder: String?
    @State private var turn = 0.0
    @State private var lifted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            DS.Colors.paper.opacity(0.86)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(AngularGradient(colors: [DS.Colors.accentSoft, DS.Colors.accent, DS.Colors.accentSoft],
                                              center: .center, angle: .degrees(turn)),
                              style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
                .padding(28)
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(DS.Colors.chip).frame(width: 84, height: 84)
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Colors.ink)
                }
                .scaleEffect(lifted ? 1.06 : 1)
                .offset(y: lifted ? -3 : 0)
                Text("Släpp för att skriva ut")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                Text(folder.map { String(localized: "Ljud eller video – texten, rösterna och anteckningarna hamnar i \($0).") }
                     ?? String(localized: "Ljud eller video – du får texten med vem som sa vad, anteckningar och kan fråga om innehållet."))
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { turn = 360 }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { lifted = true }
        }
    }
}

// MARK: - The files being imported

/// A card per file at the top of the list: what it's doing, how far it is — then
/// "Öppna". Gone by itself a while after it's done.
struct ImportCards: View {
    @ObservedObject private var importer = MeetingImport.shared
    let open: (UUID) -> Void

    var body: some View {
        if !importer.jobs.isEmpty {
            VStack(spacing: 10) {
                ForEach(importer.jobs) { job in
                    ImportCard(job: job, open: open)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.spring(duration: 0.4, bounce: 0.15), value: importer.jobs.map(\.id))
        }
    }
}

struct ImportCard: View {
    let job: MeetingImport.Job
    let open: (UUID) -> Void

    private var done: Bool { job.stage == .done }
    private var failed: Bool { job.stage == .failed }
    private static let steps: [MeetingImport.Stage] = [.reading, .writing, .voices, .notes]

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(DS.Colors.chip).frame(width: 46, height: 46)
                if !done && !failed && job.stage != .waiting {
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
            VStack(alignment: .leading, spacing: 5) {
                Text(failed ? job.url.lastPathComponent : job.name)
                    .font(.system(size: 14.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if failed {
                    Text(job.error ?? "").font(.system(size: 12.5)).foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if done {
                    Text("Klar – texten, rösterna och anteckningarna").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                } else {
                    HStack(spacing: 8) {
                        Text(job.stage.title + (job.stage == .waiting ? "" : " · \(Int(job.progress * 100)) %"))
                            .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).monospacedDigit()
                            .contentTransition(.numericText())
                        // The four steps, the one under way lit.
                        HStack(spacing: 4) {
                            ForEach(Self.steps, id: \.self) { step in
                                Capsule()
                                    .fill(step.start <= job.stage.start ? AnyShapeStyle(DS.Gradients.accent) : AnyShapeStyle(DS.Colors.chip))
                                    .frame(width: step == job.stage ? 16 : 6, height: 6)
                            }
                        }
                        .animation(.spring(duration: 0.4, bounce: 0.2), value: job.stage)
                    }
                }
            }
            Spacer(minLength: 12)
            if done, let id = job.meeting {
                Button("Öppna") {
                    open(id)
                    MeetingImport.shared.remove(job.id)
                }
                .buttonStyle(.ink)
            }
            Button { withAnimation(.snappy) { MeetingImport.shared.remove(job.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Colors.muted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(done || failed ? "Stäng" : "Avbryt importen")
            .accessibilityLabel(done || failed ? "Stäng" : "Avbryt importen")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .raised(cornerRadius: 18)
        .accessibilityElement(children: .combine)
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

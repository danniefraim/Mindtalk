import AppKit
import SwiftUI

// MARK: - Inställningar → Mindtalk i Claude
//
// Off by default. Switched on, the card says what Claude may read (everything is the
// default: the owner chose that the connection, once on, reads it all), which
// folders, how to get the connection into the Claude app and Claude Code, and what
// Claude has read so far. Switched off, only the switch, the privacy text and a line
// saying so: nothing to set for something that isn't on.

struct ClaudeSettingsCard: View {
    @ObservedObject var sharing: ClaudeSharing
    @ObservedObject private var folders = MeetingFolders.shared
    @State private var showAll = false
    @State private var confirmClear = false
    /// "Kopierat. Klistra in i Terminalen.", for a few seconds.
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    /// The Claude app wasn't found, or the bundle couldn't be written.
    @State private var trouble: String?

    private static let shown = 10

    var body: some View {
        VStack(spacing: 0) {
            header
            CardDivider()
            if sharing.enabled {
                levels
                CardDivider()
                folderRows
                CardDivider()
                install
                CardDivider()
                log
            } else {
                Text("Av. Claude kan inte läsa något.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 16)
            }
        }
        .card()
        .overlay(alignment: .bottom) {
            if let toast {
                Text(verbatim: toast).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Colors.onInk)
                    .padding(.horizontal, 16).frame(height: 38)
                    .background(Capsule().fill(DS.Colors.ink))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.12), value: toast)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: sharing.enabled)
        .confirmationDialog("Rensa loggen?", isPresented: $confirmClear) {
            Button("Rensa", role: .destructive) { withAnimation(.snappy) { sharing.clearLog() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Listan över vad Claude har läst tas bort från din Mac.")
        }
    }

    // MARK: The switch and the words that matter

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                Text("Mindtalk i Claude").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                InkToggle(label: "Mindtalk i Claude", isOn: $sharing.enabled)
            }
            Text("När du frågar Claude om dina möten skickas texten till Anthropic, enligt villkoren för ditt Claude-konto. Mindtalk skickar inget själv, Claude läser bara när du frågar. Ljud och röstavtryck delas aldrig.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Fungerar också med andra program som stöder MCP, som ChatGPT på Mac.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    // MARK: Claude får läsa

    private var levels: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Claude får läsa"))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ClaudeSharing.Level.allCases) { level in
                    InkRadio(title: level.title, on: sharing.level == level) {
                        withAnimation(.snappy) { sharing.level = level }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: Mappar

    private var folderRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Mappar"))
            if sharing.level.includesMeetings {
                if !folders.sorted.isEmpty {
                    FlowLayout(spacing: 16) {
                        ForEach(folders.sorted) { folder in
                            Toggle(isOn: Binding(
                                get: { !sharing.excludedFolders.contains(folder.id) },
                                set: { on in
                                    if on { sharing.excludedFolders.remove(folder.id) } else { sharing.excludedFolders.insert(folder.id) }
                                })) {
                                Text(verbatim: folder.name).font(.system(size: 13))
                            }
                            .toggleStyle(InkCheckboxStyle())
                        }
                    }
                }
                Text("Möten utan mapp delas.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            } else {
                Text("Med Bara tankar läser Claude inga möten, oavsett mapp.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: Lägg till i Claude, Kopiera för Claude Code

    private var install: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Lägg till i Claude") { addToClaude() }.buttonStyle(.ink)
                Button("Kopiera för Claude Code") {
                    ClaudeInstall.copyClaudeCodeCommand()
                    show(String(localized: "Kopierat. Klistra in i Terminalen."))
                }
                .buttonStyle(.soft)
            }
            .disabled(!sharing.enabled)
            if let trouble {
                HStack(spacing: 8) {
                    Text(verbatim: trouble).font(.system(size: 12.5)).foregroundStyle(.primary)
                    Button { NSWorkspace.shared.open(ClaudeInstall.downloadURL) } label: {
                        Text("Läs mer").font(.system(size: 12.5, weight: .medium)).underline()
                    }
                    .buttonStyle(.plain)
                }
            } else if sharing.entries.isEmpty {
                // Until Claude has read something there is no way to know it's installed.
                Text("Tryck Lägg till i Claude, så öppnas tillägget i Claude-appen.")
                    .font(.system(size: 12.5)).foregroundStyle(.primary)
            }
            Text("Claude-appen på Macen och Claude Code. Inte claude.ai på webben eller i mobilen.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private func addToClaude() {
        switch ClaudeInstall.addToClaude() {
        case .opened:
            trouble = nil
        case .noClaudeApp:
            trouble = String(localized: "Claude-appen hittades inte. Hämta den på claude.ai/download.")
        case .failed(let why):
            trouble = String(localized: "Tillägget kunde inte skapas: \(why)")
        }
    }

    private func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Senast läst av Claude

    private var log: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Senast läst av Claude"))
            if sharing.entries.isEmpty {
                Text("Inget läst än.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(showAll ? sharing.entries : Array(sharing.entries.prefix(Self.shown))) { entry in
                        Text(verbatim: ClaudeLogLine.text(for: entry))
                            .font(.system(size: 12.5)).monospacedDigit()
                            .foregroundStyle(DS.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 16) {
                    if sharing.entries.count > Self.shown {
                        Button(showAll ? "Visa färre" : "Visa alla") { withAnimation(.snappy) { showAll.toggle() } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                    }
                    Button("Rensa loggen…") { confirmClear = true }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}

/// One log entry in words: "I dag 15:02 · Sökte i Klang · 4 möten · 3 000 tecken".
enum ClaudeLogLine {
    static func text(for entry: ClaudeSharing.Entry) -> String {
        var parts = [MeetingRecord.when(entry.date), action(entry)]
        if let count = count(entry) { parts.append(count) }
        if entry.characters > 0 {
            let n = entry.characters.formatted(.number.locale(AppLanguage.locale))
            parts.append(String(localized: "\(n) tecken"))
        }
        return parts.joined(separator: " · ")
    }

    /// What Claude did, with where ("Sökte i Klang", "Läste Styrelsemöte 14 okt · sammanfattning").
    private static func action(_ entry: ClaudeSharing.Entry) -> String {
        let scope = entry.scope.trimmingCharacters(in: .whitespaces)
        switch entry.tool {
        case "mindtalk_search":
            return scope.isEmpty ? String(localized: "Sökte") : String(localized: "Sökte i \(scope)")
        case "mindtalk_get_meeting":
            return String(localized: "Läste \(scope) · sammanfattning")
        case "mindtalk_get_transcript":
            return String(localized: "Läste \(scope) · hela texten")
        case "mindtalk_list_meetings":
            return scope.isEmpty ? String(localized: "Listade möten") : String(localized: "Listade möten i \(scope)")
        case "mindtalk_list_folders":
            return String(localized: "Listade mapparna")
        case "mindtalk_list_tasks":
            return scope.isEmpty ? String(localized: "Läste uppgifter") : String(localized: "Läste uppgifter i \(scope)")
        case "mindtalk_list_thoughts":
            return String(localized: "Läste tankar")
        default:
            return scope.isEmpty ? entry.tool : "\(entry.tool) · \(scope)"
        }
    }

    /// How many came back, in the unit the tool deals in.
    private static func count(_ entry: ClaudeSharing.Entry) -> String? {
        let n = entry.items
        switch entry.tool {
        case "mindtalk_search", "mindtalk_list_meetings":
            return n == 1 ? String(localized: "1 möte") : String(localized: "\(n) möten")
        case "mindtalk_list_tasks":
            return n == 1 ? String(localized: "1 uppgift") : String(localized: "\(n) uppgifter")
        case "mindtalk_list_thoughts":
            return n == 1 ? String(localized: "1 tanke") : String(localized: "\(n) tankar")
        case "mindtalk_list_folders":
            return n == 1 ? String(localized: "1 mapp") : String(localized: "\(n) mappar")
        default:
            return nil
        }
    }
}

/// A radio button in ink: a ring, filled with a dot when chosen.
private struct InkRadio: View {
    let title: String
    let on: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ZStack {
                    Circle().strokeBorder(on ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: on ? 1.5 : 1)
                        .background(Circle().fill(on ? Color.clear : DS.Colors.control))
                    if on { Circle().fill(DS.Colors.ink).frame(width: 8, height: 8) }
                }
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
                Text(verbatim: title).font(.system(size: 13))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

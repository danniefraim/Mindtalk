import AppKit
import SwiftUI

// MARK: - Inställningar → Integrationer → MCP
//
// Off by default. Switched on, the card says what may be read (everything is the
// default: the owner chose that the connection, once on, reads it all), which
// folders, how to get the connection into the program the user picks (the Claude app,
// Claude Code, ChatGPT on Mac or any other that speaks MCP), and what has been read so
// far. Switched off, only the switch, the privacy text and a line saying so: nothing
// to set for something that isn't on. The app never assumes Claude: the user chooses
// the assistant.

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
                Text("Av. Inga program kan läsa något. Slår du på väljer du vad som får läsas och kopplar sedan ditt program.")
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
            Text("Listan över vad som har lästs tas bort från din Mac.")
        }
    }

    // MARK: The switch and the words that matter

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                Text("MCP").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                InkToggle(label: String(localized: "MCP, låt AI-program läsa möten och tankar"), isOn: $sharing.enabled)
            }
            Text("MCP är ett öppet sätt för AI-program att läsa dina möten och tankar. Du väljer vilket program: Claude och ChatGPT på Macen, eller andra som stöder MCP.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("När du frågar skickas texten till det programmets leverantör, enligt villkoren för ditt konto där. Mindtalk skickar inget själv. Ljud och röstavtryck delas aldrig.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    // MARK: Får läsa

    private var levels: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Får läsa"))
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
            CapsLabel(String(localized: "Mappar som får läsas"))
            if sharing.level.includesMeetings {
                if folders.sorted.isEmpty {
                    Text("Du har inga mappar än. Alla möten får läsas.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                } else {
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
                    Text("Möten utan mapp får alltid läsas. Ett nytt möte kan läsas när det är klart, om du inte lägger det i en mapp som inte får läsas.")
                        .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Med Bara tankar läses inga möten, oavsett mapp.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    // MARK: Lägg till i Claude, Kopiera för Claude Code, Kopiera för andra program

    private var install: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Three buttons: the third wraps to a row of its own when the card is narrow.
            FlowLayout(spacing: 10) {
                Button("Lägg till i Claude") { addToClaude() }.buttonStyle(.ink)
                Button("Kopiera för Claude Code") {
                    ClaudeInstall.copyClaudeCodeCommand()
                    sharing.connectedOnce = true
                    show(String(localized: "Kopierat. Klistra in i Terminalen."))
                }
                .buttonStyle(.soft)
                Button("Kopiera för andra program") {
                    ClaudeInstall.copyServerConfig()
                    sharing.connectedOnce = true
                    show(String(localized: "Kopierat. Klistra in i programmets MCP-inställningar."))
                }
                .buttonStyle(.soft)
            }
            .disabled(!sharing.enabled)
            if let trouble {
                HStack(spacing: 8) {
                    Text(verbatim: trouble).font(.system(size: 12.5)).foregroundStyle(.primary)
                    Button { NSWorkspace.shared.open(ClaudeInstall.downloadURL) } label: {
                        Text("Hämta Claude").font(.system(size: 12.5, weight: .medium)).underline()
                    }
                    .buttonStyle(.plain)
                }
            } else if sharing.connectedOnce {
                // Until something has been read there is no way to know a program is connected.
                Text("Fråga nu ditt program om ett möte, så syns det här.")
                    .font(.system(size: 12.5)).foregroundStyle(.primary)
            } else {
                Text("Tryck Lägg till i Claude, så öppnas Claude-appen och frågar om du vill lägga till Mindtalk. Eller kopiera inställningen till ditt program.")
                    .font(.system(size: 12.5)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Fungerar med program på den här Macen, inte med Claude eller ChatGPT på webben eller i mobilen.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("Alla program som körs som du på den här Macen kan fråga. Loggen visar varje läsning.")
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
            sharing.connectedOnce = true
        case .noClaudeApp:
            trouble = String(localized: "Claude-appen hittades inte.")
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

    // MARK: Senast läst

    private var log: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Senast läst"))
            if sharing.entries.isEmpty {
                Text("Inget läst än.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(showAll ? sharing.entries : Array(sharing.entries.prefix(Self.shown))) { entry in
                        // A refusal reads quieter: nothing went out.
                        Text(verbatim: ClaudeLogLine.text(for: entry))
                            .font(.system(size: 12.5)).monospacedDigit()
                            .foregroundStyle(DS.Colors.muted.opacity(entry.wasRefused ? 0.6 : 1))
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

/// One log entry in words: "I dag 15:02 · Claude sökte i Klang · 4 träffar · 3 000 tecken skickade".
/// Refused: "I dag 15:02 · Claude · nekad: hela texten".
enum ClaudeLogLine {
    static func text(for entry: ClaudeSharing.Entry) -> String {
        var parts = [MeetingRecord.when(entry.date)]
        if entry.wasRefused {
            if let client = entry.client { parts.append(client) }
            parts.append(entry.scope)
            return parts.joined(separator: " · ")
        }
        parts.append(byClient(action(entry), entry.client))
        if let count = count(entry) { parts.append(count) }
        if entry.characters > 0 {
            let n = entry.characters.formatted(.number.locale(AppLanguage.locale))
            parts.append(String(localized: "\(n) tecken skickade"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Sökte i Klang" by Claude: "Claude sökte i Klang". Unknown: as it was.
    private static func byClient(_ action: String, _ client: String?) -> String {
        guard let client, !client.isEmpty, let first = action.first else { return action }
        return client + " " + first.lowercased() + action.dropFirst()
    }

    /// What the program did, with where ("Sökte i Klang", "Läste Styrelsemöte 14 okt · sammanfattning").
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
            return entry.items == 1 ? String(localized: "Listade 1 mapp") : String(localized: "Listade \(entry.items) mappar")
        case "mindtalk_list_tasks":
            return scope.isEmpty ? String(localized: "Läste uppgifter") : String(localized: "Läste uppgifter i \(scope)")
        case "mindtalk_list_thoughts":
            return entry.items == 1 ? String(localized: "Läste 1 tanke") : String(localized: "Läste \(entry.items) tankar")
        default:
            return scope.isEmpty ? entry.tool : "\(entry.tool) · \(scope)"
        }
    }

    /// How many came back, in the unit the tool deals in (folders and thoughts say it
    /// in the action itself).
    private static func count(_ entry: ClaudeSharing.Entry) -> String? {
        let n = entry.items
        switch entry.tool {
        case "mindtalk_search":
            return n == 1 ? String(localized: "mcp|1 träff") : String(localized: "mcp|\(n) träffar")
        case "mindtalk_list_meetings":
            return n == 1 ? String(localized: "1 möte") : String(localized: "\(n) möten")
        case "mindtalk_list_tasks":
            return n == 1 ? String(localized: "1 uppgift") : String(localized: "\(n) uppgifter")
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

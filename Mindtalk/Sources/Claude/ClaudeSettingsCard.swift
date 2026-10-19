import AppKit
import SwiftUI

// MARK: - Inställningar → Integrationer → MCP
//
// Off by default. Switched on, the card fits one screen: what may be read (everything
// is the default: the owner chose that the connection, once on, reads it all), which
// folders, a picker of programs with one button that connects the chosen one, the
// Terminal command, and what has been read so far. Switched off, only the switch, the
// two sentences and a line saying so: nothing to set for something that isn't on.
//
// The first time the switch goes on, a dialog says where the text goes and what is
// never shared; after that the switch is a switch. The app never assumes Claude: the
// picker offers the program that read something last, else Claude.

struct ClaudeSettingsCard: View {
    @ObservedObject var sharing: ClaudeSharing
    @ObservedObject private var folders = MeetingFolders.shared
    /// The program the picker shows.
    @State private var client: ClaudeInstall.Client
    /// The button reads "Kopierat" for a moment after a copy.
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?
    /// The program wasn't found, or the bundle couldn't be written.
    @State private var trouble: String?
    /// /usr/local/bin/mindtalk is there and is ours.
    @State private var commandInstalled: Bool
    @State private var commandTrouble: String?
    /// "Slå på MCP?", the first time.
    @State private var askEnable = false
    @State private var showAll = false
    @State private var confirmClear = false

    private static let shown = 10
    /// The column the small-caps labels sit in, left of the levels and the folders.
    private static let labelColumn: CGFloat = 108

    /// `client`: a pick to start from (the renders); else the last program in the log, else Claude.
    init(sharing: ClaudeSharing, client: ClaudeInstall.Client? = nil) {
        self.sharing = sharing
        _client = State(initialValue: client ?? sharing.lastClient.flatMap(ClaudeInstall.Client.matching(logName:)) ?? .claude)
        _commandInstalled = State(initialValue: ClaudeInstall.commandInstalled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            CardDivider()
            if sharing.enabled {
                permissions
                CardDivider()
                connect
                CardDivider()
                terminal
                CardDivider()
                log
            } else {
                Text("Av. Inga program kan läsa något.")
                    .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 16)
            }
        }
        .card()
        .animation(.spring(duration: 0.3, bounce: 0.1), value: sharing.enabled)
        .onAppear { commandInstalled = ClaudeInstall.commandInstalled }
        .alert("Slå på MCP?", isPresented: $askEnable) {
            Button("Slå på") {
                sharing.enableExplained = true
                withAnimation(.spring(duration: 0.25, bounce: 0.2)) { sharing.enabled = true }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("När du frågar ett AI-program skickas texten till det programmets leverantör, enligt villkoren för ditt konto där. Mindtalk skickar inget själv. Ljud och röstavtryck delas aldrig. Alla program som körs som du på den här Macen kan fråga, och loggen visar varje läsning.")
        }
        .confirmationDialog("Rensa loggen?", isPresented: $confirmClear) {
            Button("Rensa", role: .destructive) { withAnimation(.snappy) { sharing.clearLog() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Listan över vad som har lästs tas bort från din Mac.")
        }
    }

    // MARK: The switch and the two sentences

    /// On, the first time, goes through the dialog; off is immediate.
    private var enabled: Binding<Bool> {
        Binding(get: { sharing.enabled }, set: { on in
            if on, !sharing.enableExplained { askEnable = true } else { sharing.enabled = on }
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                Text("MCP").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                InkToggle(label: String(localized: "MCP, låt AI-program läsa möten och tankar"), isOn: enabled)
            }
            Text("Låt din AI-assistent läsa dina möten och tankar på den här Macen. Inget delas förrän du slår på, och varje läsning syns i loggen.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 18)
    }

    // MARK: Får läsas, Mappar

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CapsLabel(String(localized: "Får läsas")).frame(width: Self.labelColumn, alignment: .leading)
                // One row when the three fit, else one under the other.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) { levelRadios }
                    VStack(alignment: .leading, spacing: 8) { levelRadios }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                CapsLabel(String(localized: "Mappar"))
                    .frame(width: Self.labelColumn, alignment: .leading)
                    .help("Ett nytt möte kan läsas när det är klart, om du inte lägger det i en mapp som inte får läsas.")
                folderRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var levelRadios: some View {
        ForEach(ClaudeSharing.Level.allCases) { level in
            InkRadio(title: level.title, on: sharing.level == level) {
                withAnimation(.snappy) { sharing.level = level }
            }
        }
    }

    @ViewBuilder private var folderRow: some View {
        if !sharing.level.includesMeetings {
            Text("Med Bara tankar läses inga möten, oavsett mapp.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
        } else if folders.sorted.isEmpty {
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
                Text("Möten utan mapp får alltid läsas.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
        }
    }

    // MARK: Koppla ett program

    private var connect: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Koppla ett program"))
            HStack(spacing: 12) {
                Text("Program").font(.system(size: 13))
                MenuPicker(options: ClaudeInstall.Client.allCases.map { ($0, $0.title) },
                           selection: Binding(get: { client }, set: { pick($0) }))
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                actionButton
                Text(verbatim: client.hint)
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let trouble {
                HStack(spacing: 8) {
                    Text(verbatim: trouble).font(.system(size: 12.5)).foregroundStyle(.primary)
                    if client == .claude {
                        Button { NSWorkspace.shared.open(ClaudeInstall.downloadURL) } label: {
                            Text("Hämta Claude").font(.system(size: 12.5, weight: .medium)).underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("Starta om programmet efteråt.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    /// One button: ink for the Claude app (the one-click way), soft for the rest.
    @ViewBuilder private var actionButton: some View {
        switch client.action {
        case .addToClaude:
            Button("Lägg till i Claude") { addToClaude() }.buttonStyle(.ink)
        case .copy(let title, let text):
            Button(copied ? String(localized: "Kopierat") : title) { copy(text) }.buttonStyle(.soft)
        case .open(let title, let url):
            Button(title) { open(url) }.buttonStyle(.soft)
        }
    }

    private func pick(_ picked: ClaudeInstall.Client) {
        withAnimation(.snappy) {
            client = picked
            trouble = nil
            copied = false
        }
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

    private func copy(_ text: String) {
        ClaudeInstall.copy(text, what: "the setting for \(client.rawValue)")
        sharing.connectedOnce = true
        trouble = nil
        copied = true
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private func open(_ url: URL) {
        switch ClaudeInstall.open(url) {
        case .opened:
            trouble = nil
            sharing.connectedOnce = true
        case .notInstalled:
            trouble = client.notFound
        }
    }

    // MARK: Terminalen

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 10) {
            CapsLabel(String(localized: "Terminalen"))
            HStack(alignment: .center, spacing: 16) {
                Text(verbatim: commandInstalled ? "mindtalk finns i /usr/local/bin · mindtalk --help" : "mindtalk meetings · search · thoughts …")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(commandInstalled ? .primary : DS.Colors.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Button(commandInstalled ? "Ta bort kommandot" : "Installera kommandot") { toggleCommand() }
                    .buttonStyle(.soft)
            }
            if let commandTrouble {
                Text(verbatim: commandTrouble).font(.system(size: 12.5)).foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    /// The system asks for the password: /usr/local/bin belongs to root.
    private func toggleCommand() {
        let outcome = commandInstalled ? ClaudeInstall.removeCommand() : ClaudeInstall.installCommand()
        switch outcome {
        case .success:
            commandTrouble = nil
        case .failure(.cancelled):
            commandTrouble = nil
        case .failure(let why):
            commandTrouble = commandInstalled
                ? String(localized: "Kommandot kunde inte tas bort: \(why.localizedDescription)")
                : String(localized: "Kommandot kunde inte installeras: \(why.localizedDescription)")
        }
        withAnimation(.snappy) { commandInstalled = ClaudeInstall.commandInstalled }
    }

    // MARK: Senast läst

    private var log: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                CapsLabel(String(localized: "Senast läst"))
                Spacer(minLength: 12)
                if sharing.entries.count > Self.shown || showAll {
                    Button(showAll ? "Visa färre" : "Visa loggen") { withAnimation(.snappy) { showAll.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                }
                if !sharing.entries.isEmpty {
                    Button("Rensa…") { confirmClear = true }
                        .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                }
            }
            if sharing.entries.isEmpty {
                Text("Inget läst än.").font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(showAll ? sharing.entries : Array(sharing.entries.prefix(Self.shown))) { entry in
                        // A refusal reads quieter: nothing went out.
                        Text(verbatim: ClaudeLogLine.text(for: entry, detailed: showAll))
                            .font(.system(size: 12.5)).monospacedDigit()
                            .foregroundStyle(DS.Colors.muted.opacity(entry.wasRefused ? 0.6 : 1))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}

/// One log entry in words: "I dag 15:02 · Claude sökte i Klang, 4 träffar", and with
/// `detailed` the size too: "… · 3 000 tecken skickade".
/// Refused: "I dag 15:02 · Claude · nekad: hela texten".
enum ClaudeLogLine {
    static func text(for entry: ClaudeSharing.Entry, detailed: Bool = true) -> String {
        var parts = [MeetingRecord.when(entry.date)]
        if entry.wasRefused {
            if let client = entry.client { parts.append(client) }
            parts.append(entry.scope)
            return parts.joined(separator: " · ")
        }
        parts.append(byClient(action(entry), entry.client))
        if detailed, entry.characters > 0 {
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

    /// What the program did, with where and how much ("Sökte i Klang, 4 träffar",
    /// "Listade 10 möten i Kunder", "Läste Styrelsemöte 14 okt · sammanfattning").
    private static func action(_ entry: ClaudeSharing.Entry) -> String {
        let scope = entry.scope.trimmingCharacters(in: .whitespaces)
        // "Alla möten" inside a sentence: "sökte i alla möten".
        let place = scope == String(localized: "Alla möten") ? String(localized: "alla möten") : scope
        let n = entry.items
        switch entry.tool {
        case "mindtalk_search":
            let hits = n == 0 ? String(localized: "inga träffar") : n == 1 ? String(localized: "mcp|1 träff") : String(localized: "mcp|\(n) träffar")
            return place.isEmpty ? String(localized: "Sökte, \(hits)") : String(localized: "Sökte i \(place), \(hits)")
        case "mindtalk_get_meeting":
            return String(localized: "Läste \(scope) · sammanfattning")
        case "mindtalk_get_transcript":
            return String(localized: "Läste \(scope) · hela texten")
        case "mindtalk_list_meetings":
            let meetings = n == 1 ? String(localized: "1 möte") : String(localized: "\(n) möten")
            return place.isEmpty || scope == String(localized: "Alla möten")
                ? String(localized: "Listade \(meetings)") : String(localized: "Listade \(meetings) i \(scope)")
        case "mindtalk_list_folders":
            return n == 1 ? String(localized: "Listade 1 mapp") : String(localized: "Listade \(n) mappar")
        case "mindtalk_list_tasks":
            let tasks = n == 1 ? String(localized: "1 uppgift") : String(localized: "\(n) uppgifter")
            return place.isEmpty || scope == String(localized: "Alla möten")
                ? String(localized: "Läste \(tasks)") : String(localized: "Läste \(tasks) i \(scope)")
        case "mindtalk_list_thoughts":
            return n == 1 ? String(localized: "Läste 1 tanke") : String(localized: "Läste \(n) tankar")
        default:
            return scope.isEmpty ? entry.tool : "\(entry.tool) · \(scope)"
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

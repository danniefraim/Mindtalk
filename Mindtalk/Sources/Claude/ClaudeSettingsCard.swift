import AppKit
import SwiftUI

// MARK: - Inställningar → Integrationer → MCP
//
// Off by default. The serif line on top says what it is for, off and on. Switched on,
// the card fits one screen: a row of buttons for the four programs people ask for
// (Claude, ChatGPT, Cursor, Gemini CLI), three steps for all other programs with the
// standard setting to copy, and a "Läs mer" that opens the help page (MCPHelpView,
// every program step by step, and the Terminal command). Then what has been read so far.
// On means everything Mindtalk has may be read; off means nothing: switching on is the
// choice, so there is nothing more to set. Switched off: the switch, the two lines on
// top and a line saying so.
//
// The first time the switch goes on, a dialog says where the text goes and what is
// never shared; after that the switch is a switch.

struct ClaudeSettingsCard: View {
    @ObservedObject var sharing: ClaudeSharing
    /// The button that reads "Kopierat" for a moment after a copy.
    @State private var copied: ClaudeInstall.Client?
    @State private var copiedTask: Task<Void, Never>?
    /// The line under the buttons: what to do with the copy, or what went wrong.
    @State private var notice: Notice?
    @State private var noticeTask: Task<Void, Never>?
    /// "Slå på MCP?", the first time.
    @State private var askEnable = false
    @State private var showAll = false
    @State private var confirmClear = false
    /// The help page, from "Läs mer".
    @State private var showHelp = false

    private static let shown = 10

    private enum Notice: Equatable {
        /// Muted, and gone after a few seconds.
        case copied(String)
        /// In ink, until the next press; for the Claude app with "Hämta Claude" beside it.
        case trouble(String, getClaude: Bool)
    }

    /// `preview`: the renders, as right after pressing that program's button.
    init(sharing: ClaudeSharing, preview: ClaudeInstall.Client? = nil) {
        self.sharing = sharing
        switch preview {
        case .codex, .gemini:
            _copied = State(initialValue: preview)
            _notice = State(initialValue: .copied(Self.copiedLine(preview!)))
        case .cursor:
            _notice = State(initialValue: .trouble(ClaudeInstall.Client.cursor.notFound, getClaude: false))
        case .claude:
            _notice = State(initialValue: .trouble(String(localized: "Claude-appen hittades inte."), getClaude: true))
        default:
            break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            CardDivider()
            if sharing.enabled {
                connect
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
        .alert("Slå på MCP?", isPresented: $askEnable) {
            Button("Slå på") {
                sharing.enableExplained = true
                withAnimation(.spring(duration: 0.25, bounce: 0.2)) { sharing.enabled = true }
            }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Programmen du kopplar kan då läsa dina tankar, mötenas sammanfattningar, dina anteckningar och mötenas hela text. När du frågar ett AI-program skickas texten till det programmets leverantör, enligt villkoren för ditt konto där. Mindtalk skickar inget själv. Ljud och röstavtryck delas aldrig. Alla program som körs som du på den här Macen kan fråga, och loggen visar varje läsning.")
        }
        .confirmationDialog("Rensa loggen?", isPresented: $confirmClear) {
            Button("Rensa", role: .destructive) { withAnimation(.snappy) { sharing.clearLog() } }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Listan över vad som har lästs tas bort från din Mac.")
        }
        .sheet(isPresented: $showHelp) {
            MCPHelpView(sharing: sharing) { showHelp = false }
        }
    }

    // MARK: The switch and the two lines

    /// On, the first time, goes through the dialog; off is immediate.
    private var enabled: Binding<Bool> {
        Binding(get: { sharing.enabled }, set: { on in
            if on, !sharing.enableExplained { askEnable = true } else { sharing.enabled = on }
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                Text("MCP").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                InkToggle(label: String(localized: "MCP, låt AI-program läsa möten och tankar"), isOn: enabled)
            }
            Text("Ta med dina möten och tankar till din AI-assistent")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Text("Slår du på kan programmen du kopplar läsa dina tankar och möten, även hela texten. Varje läsning syns i loggen.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
    }

    // MARK: The four buttons, and all other programs

    private var connect: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 10) {
                Button("Lägg till i Claude") { addToClaude() }
                    .buttonStyle(.ink)
                    .help("Skapar ett tillägg och öppnar det i Claude-appen.")
                copyButton(.codex, title: "ChatGPT")
                    .help("Kopierar kommandot som lägger till Mindtalk i ChatGPT:s Codex.")
                Button { open(.cursor) } label: { Text(verbatim: "Cursor") }
                    .buttonStyle(.soft)
                    .help("Öppnar Cursor, som frågar om du vill lägga till Mindtalk.")
                copyButton(.gemini, title: "Gemini CLI")
                    .help("Kopierar kommandot som lägger till Mindtalk i Gemini CLI.")
            }
            if let notice { noticeLine(notice).padding(.top, 10) }

            Text("Alla andra program")
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 22).padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 0) {
                    StepNumber(1)
                    Text("steg|Kopiera inställningen").font(.system(size: 13)).fixedSize()
                        .padding(.trailing, 12)
                    MCPCopyField(text: ClaudeInstall.serverConfig(), what: "the MCP server config") {
                        sharing.connectedOnce = true
                    }
                }
                step(2, "Lägg till den i programmets MCP-inställningar, som en lokal server (STDIO).")
                step(3, "Starta om programmet och fråga om dina möten.")
            }
            HStack {
                Spacer()
                Button { showHelp = true } label: {
                    HStack(spacing: 3) {
                        Text("Läs mer")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                .help("Hur du kopplar Mindtalk till varje program.")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            StepNumber(number)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A soft button that reads "Kopierat" for a moment, as wide as the wider of the two
    /// so the row doesn't move.
    private func copyButton(_ client: ClaudeInstall.Client, title: String) -> some View {
        Button { copy(client) } label: {
            ZStack {
                Text(verbatim: title).opacity(copied == client ? 0 : 1)
                Text("Kopierat").opacity(copied == client ? 1 : 0)
            }
        }
        .buttonStyle(.soft)
    }

    @ViewBuilder private func noticeLine(_ notice: Notice) -> some View {
        switch notice {
        case .copied(let text):
            Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .trouble(let text, let getClaude):
            HStack(spacing: 8) {
                Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(.primary)
                if getClaude {
                    Button { NSWorkspace.shared.open(ClaudeInstall.downloadURL) } label: {
                        Text("Hämta Claude").font(.system(size: 12.5, weight: .medium)).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private static func copiedLine(_ client: ClaudeInstall.Client) -> String {
        client == .codex
            ? String(localized: "Kopierat. Klistra in i Terminalen, så kan ChatGPT:s Codex använda Mindtalk.")
            : String(localized: "Kopierat. Klistra in i Terminalen.")
    }

    private func say(_ new: Notice?) {
        noticeTask?.cancel()
        withAnimation(.snappy) { notice = new }
        guard case .copied = new else { return }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(.snappy) { notice = nil } }
        }
    }

    private func addToClaude() {
        let outcome = ClaudeInstall.addToClaude()
        if outcome == .opened { sharing.connectedOnce = true }
        say(outcome.trouble.map { .trouble($0, getClaude: outcome == .noClaudeApp) })
    }

    /// ChatGPT and Gemini CLI: the program's `… mcp add` line, from its action.
    private func copy(_ client: ClaudeInstall.Client) {
        guard case .copy(_, let text) = client.action else { return }
        ClaudeInstall.copy(text, what: "the command for \(client.rawValue)")
        sharing.connectedOnce = true
        copiedTask?.cancel()
        withAnimation(.snappy) { copied = client }
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(.snappy) { copied = nil } }
        }
        say(.copied(Self.copiedLine(client)))
    }

    private func open(_ client: ClaudeInstall.Client) {
        guard case .open(_, let url) = client.action else { return }
        switch ClaudeInstall.open(url) {
        case .opened:
            sharing.connectedOnce = true
            say(nil)
        case .notInstalled:
            say(.trouble(client.notFound, getClaude: false))
        }
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
/// Refused: "I dag 15:02 · Claude · nekad: hela texten", and when it came again and
/// again: "… · nekad: avstängt · 12 gånger".
enum ClaudeLogLine {
    static func text(for entry: ClaudeSharing.Entry, detailed: Bool = true) -> String {
        var parts = [MeetingRecord.when(entry.date)]
        if entry.wasRefused {
            if let client = entry.client { parts.append(client) }
            parts.append(entry.scope)
            if let times = entry.times, times > 1 { parts.append(String(localized: "\(times) gånger")) }
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

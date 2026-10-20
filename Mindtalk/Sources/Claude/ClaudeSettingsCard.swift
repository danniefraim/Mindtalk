import AppKit
import SwiftUI

// MARK: - Inställningar → AI-appar → MCP
//
// Off by default. One row on top, MCP and the switch, with a line that says what it does
// and that dictations are never shared. Switched on, the card fits one screen: two
// buttons, Claude and ChatGPT, with a small link under them that copies the Claude Code
// command; three steps for all other programs with the standard setting to copy; and a
// "Läs mer" that opens the help page (MCPHelpView: Claude and ChatGPT, then every
// developer tool step by step, and the Terminal command). Then what has been read so
// far. On means everything Mindtalk has may be read; off means nothing: switching on is
// the choice, so there is nothing more to set. Switched off: the row and a line saying
// so. Run from outside Applications, or without the helper's link, a line says the
// apps won't find it.
//
// The first time the switch goes on, a dialog says where the text goes and what is
// never shared; after that the switch is a switch.

struct ClaudeSettingsCard: View {
    @ObservedObject var sharing: ClaudeSharing
    /// "Kopierat." in place of the Claude Code link, for a moment.
    @State private var codeCopied = false
    @State private var copiedTask: Task<Void, Never>?
    /// The lines under the buttons: what happens next, or what went wrong.
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
        /// Muted, and gone after a while.
        case said(String)
        /// The four ChatGPT steps, until the next press.
        case chatGPT
        /// In ink, until the next press, with a button to get the app.
        case trouble(String, get: GetApp?)
    }

    /// The app a "Hämta" button beside a trouble line gets.
    private enum GetApp: Equatable {
        case claude, chatGPT
        var title: String { self == .claude ? String(localized: "Hämta Claude") : String(localized: "Hämta ChatGPT") }
        var url: URL { self == .claude ? ClaudeInstall.downloadURL : ClaudeInstall.chatGPTDownloadURL }
    }

    /// The renders (`--render-mcp --client …`): as right after a press.
    enum Preview: String {
        case claude, claudeMissing = "claude-missing", chatGPT = "chatgpt", chatGPTMissing = "chatgpt-missing"
        case claudeCode = "claude-code"
    }

    init(sharing: ClaudeSharing, preview: Preview? = nil) {
        self.sharing = sharing
        switch preview {
        case .claude: _notice = State(initialValue: .said(ClaudeInstall.claudeOpensStep))
        case .claudeMissing: _notice = State(initialValue: .trouble(String(localized: "Claude-appen hittades inte."), get: .claude))
        case .chatGPT: _notice = State(initialValue: .chatGPT)
        case .chatGPTMissing: _notice = State(initialValue: .trouble(String(localized: "ChatGPT-appen hittades inte."), get: .chatGPT))
        case .claudeCode: _codeCopied = State(initialValue: true)
        case nil: break
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Everything else stays on the Mac; this is the one way text leaves it. Said
            // plainly, every time, not only in the first-time dialog.
            Text("Det Claude eller ChatGPT läser här skickas till deras servrar, som när du klistrar in text i chatten. Ljud och röstavtryck stannar alltid på din Mac.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, -6).padding(.bottom, 16)
            if !ClaudeInstall.helperReachable {
                Text("Flytta Mindtalk till mappen Program och öppna den igen, annars hittar AI-apparna inte Mindtalk.")
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.bottom, 16)
            }
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
            Text("AI-apparna du kopplar kan då läsa dina tankar, mötenas sammanfattningar, dina anteckningar och mötenas hela text. När du frågar en AI-app skickas texten till appens leverantör, enligt villkoren för ditt konto där. Mindtalk skickar inget själv. Ljud, röstavtryck och dikteringar delas aldrig. Alla program som körs som du på den här Macen kan fråga, och loggen visar varje läsning.")
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

    // MARK: The switch and its line

    /// On, the first time, goes through the dialog; off is immediate.
    private var enabled: Binding<Bool> {
        Binding(get: { sharing.enabled }, set: { on in
            if on, !sharing.enableExplained { askEnable = true } else { sharing.enabled = on }
        })
    }

    private var header: some View {
        CardRow(title: "MCP",
                detail: "Låt Claude, ChatGPT och andra AI-appar läsa dina möten och tankar, så kan du fråga dem om allt ni sagt. Dina dikteringar delas inte.") {
            InkToggle(label: String(localized: "MCP, låt AI-appar läsa möten och tankar"), isOn: enabled)
        }
    }

    // MARK: Claude and ChatGPT, and all other programs

    private var connect: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The Claude Code link beside the buttons, or under them when the card is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { buttons; claudeCodeLink }
                VStack(alignment: .leading, spacing: 10) { buttons; claudeCodeLink }
            }
            if let notice { noticeView(notice).padding(.top, 12) }

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
                step(2, LocalizedStringKey(ClaudeInstall.pasteSettingStep))
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

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Lägg till i Claude") { addToClaude() }
                .buttonStyle(.ink)
                .help("Skapar ett tillägg och öppnar det i Claude-appen.")
            Button { addToChatGPT() } label: { Text(verbatim: "ChatGPT") }
                .buttonStyle(.soft)
                .help("Kopierar sökvägen och öppnar ChatGPT-appen.")
        }
        .fixedSize()
    }

    /// "Använder du Claude Code? Kopiera kommandot.", and "Kopierat." for a moment after.
    private var claudeCodeLink: some View {
        Button { copyClaudeCode() } label: {
            ZStack(alignment: .leading) {
                Text("Använder du Claude Code? Kopiera kommandot.").opacity(codeCopied ? 0 : 1)
                Text("Kopierat.").opacity(codeCopied ? 1 : 0)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
        .help("Kopierar kommandot som lägger till Mindtalk i Claude Code.")
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            StepNumber(number)
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func noticeView(_ notice: Notice) -> some View {
        switch notice {
        case .said(let text):
            Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
        case .chatGPT:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ClaudeInstall.chatGPTSteps.enumerated()), id: \.offset) { index, text in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        StepNumber(index + 1)
                        Text(verbatim: text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(verbatim: ClaudeInstall.chatGPTWhere)
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        case .trouble(let text, let get):
            HStack(spacing: 8) {
                Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(.primary)
                if let get {
                    Button { NSWorkspace.shared.open(get.url) } label: {
                        Text(verbatim: get.title).font(.system(size: 12.5, weight: .medium)).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func say(_ new: Notice?) {
        noticeTask?.cancel()
        withAnimation(.snappy) { notice = new }
        guard case .said = new else { return }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { withAnimation(.snappy) { notice = nil } }
        }
    }

    private func addToClaude() {
        let outcome = ClaudeInstall.addToClaude()
        if outcome == .opened { sharing.connectedOnce = true }
        // Opened: what happens next in Claude, as on the help page.
        say(outcome.trouble.map { .trouble($0, get: outcome == .noClaudeApp ? .claude : nil) } ?? .said(ClaudeInstall.claudeOpensStep))
    }

    /// The helper's path to the clipboard and the ChatGPT app opened, with the steps
    /// for its settings under the buttons.
    private func addToChatGPT() {
        switch ClaudeInstall.addToChatGPT() {
        case .opened:
            sharing.connectedOnce = true
            say(.chatGPT)
        case .notInstalled:
            say(.trouble(String(localized: "ChatGPT-appen hittades inte."), get: .chatGPT))
        }
    }

    /// Claude Code: its `claude mcp add` line, and "Kopierat." for a moment.
    private func copyClaudeCode() {
        ClaudeInstall.copyClaudeCodeCommand()
        sharing.connectedOnce = true
        copiedTask?.cancel()
        withAnimation(.snappy) { codeCopied = true }
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { withAnimation(.snappy) { codeCopied = false } }
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
            parts.append(LogScope.shown(entry.scope))
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
        let mark = LogScope.mark(entry.scope)
        let all = mark == LogScope.all
        let scope = LogScope.shown(entry.scope).trimmingCharacters(in: .whitespaces)
        // All meetings inside a sentence: "sökte i alla möten".
        let place = all ? String(localized: "alla möten") : scope
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
            return place.isEmpty || all
                ? String(localized: "Listade \(meetings)") : String(localized: "Listade \(meetings) i \(scope)")
        case "mindtalk_list_folders":
            return n == 1 ? String(localized: "Listade 1 mapp") : String(localized: "Listade \(n) mappar")
        case "mindtalk_list_tasks":
            let tasks = n == 1 ? String(localized: "1 uppgift") : String(localized: "\(n) uppgifter")
            return place.isEmpty || all
                ? String(localized: "Läste \(tasks)") : String(localized: "Läste \(tasks) i \(scope)")
        case "mindtalk_list_thoughts":
            return n == 1 ? String(localized: "Läste 1 tanke") : String(localized: "Läste \(n) tankar")
        default:
            return scope.isEmpty ? entry.tool : "\(entry.tool) · \(scope)"
        }
    }
}

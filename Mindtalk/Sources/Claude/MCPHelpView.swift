import AppKit
import SwiftUI

// MARK: - Integrationer → MCP → Läs mer
//
// The help page, a sheet from the card's "Läs mer": one section per program with one to
// three numbered steps, a copy field with the exact command or setting where there is
// one, and the program's own button where it has a link. Then the Terminal command, for
// those who write commands or scripts of their own, and Felsökning last.
//
// Every command, setting and link comes from ClaudeInstall; nothing is written twice.

struct MCPHelpView: View {
    @ObservedObject var sharing: ClaudeSharing
    let close: () -> Void
    /// Screenshots: the whole page at once, without the scroll view.
    var plain = false
    /// A program wasn't found, or the bundle couldn't be written, said under its name.
    @State private var trouble: [ClaudeInstall.Client: String] = [:]
    /// /usr/local/bin/mindtalk is there and is ours.
    @State private var commandInstalled = ClaudeInstall.commandInstalled
    @State private var commandTrouble: String?

    var body: some View {
        VStack(spacing: 0) {
            if plain {
                content
            } else {
                ScrollView { content }.scrollContentBackground(.hidden)
            }
            Rectangle().fill(DS.Colors.divider).frame(height: 1)
            HStack {
                Spacer()
                Button("Klar", action: close)
                    .buttonStyle(.ink)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 620)
        .frame(height: plain ? nil : 660)
        .background(DS.Colors.paper)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Koppla Mindtalk till din AI-assistent")
                .font(.system(size: 30, weight: .regular, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            Text("MCP är ett öppet sätt för AI-program att läsa dina möten och tankar. Mindtalk kör en liten server på din Mac som programmet startar själv. Det fungerar i program på Macen, inte på webben eller i mobilen.")
                .font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            ForEach(Self.programs) { section in
                Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.vertical, 22)
                sectionView(section)
            }
            Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.vertical, 22)
            terminal
            Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.vertical, 22)
            sectionView(Self.troubleshooting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 30)
        .onAppear { commandInstalled = ClaudeInstall.commandInstalled }
    }

    // MARK: Terminalen

    /// The command in /usr/local/bin, for those who type commands or write scripts. The
    /// programs above start the helper themselves and don't need it.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Använd Mindtalk i Terminalen").font(.system(size: 14, weight: .semibold))
            Text("För dig som vill skriva kommandon eller bygga egna skript. AI-programmen ovan behöver inte detta.")
                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                Button(commandInstalled ? "Ta bort kommandot" : "Installera kommandot") { toggleCommand() }
                    .buttonStyle(.soft)
                Text(commandInstalled ? "Installerat i /usr/local/bin." : "Macen frågar efter ditt lösenord en gång.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            if let commandTrouble {
                Text(verbatim: commandTrouble).font(.system(size: 12.5)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 5) {
                command("mindtalk meetings", "dina möten")
                command("mindtalk search offerten", "sök i möten och tankar")
                command("mindtalk thoughts", "dina tankar")
                command("mindtalk tasks", "uppgifter från möten")
            }
            .padding(.top, 6)
            Text("Lägg till --json för skript.")
                .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func command(_ line: String, _ what: LocalizedStringKey) -> some View {
        GridRow {
            Text(verbatim: line).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
            Text(what).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
        }
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

    // MARK: One program

    @ViewBuilder private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text(verbatim: section.title).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                if let client = section.client { actionButton(client) }
            }
            if let client = section.client, let why = trouble[client] {
                HStack(spacing: 8) {
                    Text(verbatim: why).font(.system(size: 12.5)).foregroundStyle(.primary)
                    if client == .claude {
                        Button { NSWorkspace.shared.open(ClaudeInstall.downloadURL) } label: {
                            Text("Hämta Claude").font(.system(size: 12.5, weight: .medium)).underline()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            ForEach(Array(section.lines.enumerated()), id: \.offset) { index, line in
                lineView(line, number: section.number(of: index))
            }
        }
    }

    /// The program's own button, right of its name: the .mcpb for the Claude app, the
    /// link for the programs that have one. The rest copy from a field below.
    @ViewBuilder private func actionButton(_ client: ClaudeInstall.Client) -> some View {
        switch client.action {
        case .addToClaude:
            Button("Lägg till i Claude") {
                let outcome = ClaudeInstall.addToClaude()
                if outcome == .opened { sharing.connectedOnce = true }
                withAnimation(.snappy) { trouble[client] = outcome.trouble }
            }
            .buttonStyle(.ink)
        case .open(let title, let url):
            Button(title) {
                let outcome = ClaudeInstall.open(url)
                if outcome == .opened { sharing.connectedOnce = true }
                withAnimation(.snappy) { trouble[client] = outcome == .opened ? nil : client.notFound }
            }
            .buttonStyle(.soft)
        case .copy:
            EmptyView()
        }
    }

    @ViewBuilder private func lineView(_ line: Line, number: Int?) -> some View {
        switch line {
        case .step(let text):
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                StepNumber(number ?? 0)
                Text(verbatim: text).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .copy(let label, let text, let what):
            HStack(alignment: .center, spacing: 0) {
                StepNumber(number ?? 0)
                Text(verbatim: label).font(.system(size: 13)).fixedSize()
                    .padding(.trailing, 12)
                MCPCopyField(text: text, what: what) { sharing.connectedOnce = true }
            }
        case .note(let text):
            Text(verbatim: text).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .field(let text, let what):
            MCPCopyField(text: text, what: what) { sharing.connectedOnce = true }
        case .ask(let question, let answer):
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: question).font(.system(size: 13, weight: .semibold))
                Text(verbatim: answer).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: The page's text

    fileprivate enum Line {
        /// A numbered step.
        case step(String)
        /// A numbered step with the field to copy from on the same row.
        case copy(String, text: String, what: String)
        /// A quieter line, not a step.
        case note(String)
        /// A field on its own, under a note.
        case field(String, what: String)
        /// Felsökning: a question and its answer.
        case ask(String, String)

        var isStep: Bool {
            switch self {
            case .step, .copy: return true
            default: return false
            }
        }
    }

    fileprivate struct Section: Identifiable {
        let title: String
        /// The program, when the section has its button.
        var client: ClaudeInstall.Client? = nil
        let lines: [Line]
        var id: String { title }

        /// 1, 2, 3 for the steps; nil for the rest.
        func number(of index: Int) -> Int? {
            guard lines[index].isStep else { return nil }
            return lines[...index].filter(\.isStep).count
        }
    }

    private static var programs: [Section] { ClaudeInstall.Client.allCases.map(section(for:)) }

    private static var troubleshooting: Section {
        Section(title: String(localized: "Felsökning"), lines: [
            .ask(String(localized: "Syns inget i loggen?"),
                 String(localized: "Kontrollera att MCP är på här, och starta om programmet.")),
            .ask(String(localized: "Programmet säger att Mindtalk inte kör?"),
                 String(localized: "Öppna Mindtalk.")),
            .ask(String(localized: "Vill du stänga av?"),
                 String(localized: "Slå av MCP här. Inget kan läsas från den stunden.")),
        ])
    }

    /// What is copied comes from the program's action, so the card, the page and
    /// `--write-mcpb` always agree.
    private static func copied(_ client: ClaudeInstall.Client) -> String {
        if case .copy(_, let text) = client.action { return text }
        return ClaudeInstall.serverConfig()
    }

    private static func section(for client: ClaudeInstall.Client) -> Section {
        let copyCommand = String(localized: "steg|Kopiera kommandot")
        let copySetting = String(localized: "steg|Kopiera inställningen")
        let paste = String(localized: "Klistra in i Terminalen.")
        switch client {
        case .claude:
            return Section(title: String(localized: "Claude-appen"), client: client, lines: [
                .step(String(localized: "Tryck Lägg till i Claude.")),
                .step(String(localized: "Claude öppnas och frågar om du vill lägga till Mindtalk. Svara ja.")),
                .step(String(localized: "Fråga Claude om dina möten.")),
            ])
        case .claudeCode:
            return Section(title: client.title, lines: [
                .copy(copyCommand, text: copied(client), what: "the Claude Code command"),
                .step(paste),
                .step(String(localized: "Skriv /mcp i Claude Code för att se att Mindtalk är kopplat.")),
            ])
        case .codex:
            return Section(title: client.title, lines: [
                .copy(copyCommand, text: copied(client), what: "the Codex command"),
                .step(paste),
                .note(String(localized: "Eller i ChatGPT-appen: Inställningar → MCP servers → Add server, välj STDIO, kommandot \(ClaudeInstall.helperLinkURL.path) och argumentet mcp.")),
                .note(String(localized: "Inte under Pluginer, där går bara servrar på internet.")),
                .note(String(localized: "Det fungerar i Codex-delen av ChatGPT, inte i den vanliga chatten.")),
            ])
        case .cursor:
            return Section(title: client.title, client: client, lines: [
                .note(String(localized: "Cursor öppnas och frågar om du vill lägga till Mindtalk.")),
                .note(String(localized: "Eller lägg in inställningen i ~/.cursor/mcp.json.")),
                .field(ClaudeInstall.serverConfig(), what: "the MCP server config for Cursor"),
            ])
        case .vscode:
            return Section(title: client.title, client: client, lines: [
                .note(String(localized: "VS Code öppnas och frågar om du vill lägga till Mindtalk.")),
            ])
        case .zed:
            return Section(title: client.title, lines: [
                .copy(copySetting, text: copied(client), what: "the Zed setting"),
                .step(String(localized: "Klistra in i Zeds settings.json.")),
            ])
        case .gemini:
            return Section(title: client.title, lines: [
                .copy(copyCommand, text: copied(client), what: "the Gemini CLI command"),
                .step(paste),
            ])
        case .lmStudio:
            return Section(title: client.title, client: client, lines: [
                .note(String(localized: "LM Studio öppnas och frågar om du vill lägga till Mindtalk.")),
            ])
        case .raycast:
            return Section(title: client.title, client: client, lines: [
                .note(String(localized: "Raycast öppnas och frågar om du vill lägga till Mindtalk.")),
            ])
        case .other:
            return Section(title: String(localized: "Andra program"), lines: [
                .copy(copySetting, text: copied(client), what: "the MCP server config"),
                .step(String(localized: "Lägg till den som en lokal server (STDIO) i programmets MCP-inställningar.")),
                .step(String(localized: "Starta om programmet och fråga om dina möten.")),
            ])
        }
    }
}

/// "1." in the column left of a step.
struct StepNumber: View {
    let number: Int
    init(_ number: Int) { self.number = number }
    var body: some View {
        Text(verbatim: "\(number).")
            .font(.system(size: 13)).monospacedDigit()
            .foregroundStyle(DS.Colors.muted)
            .frame(width: 22, alignment: .leading)
    }
}

/// A command or a setting in a field, on one line, with a button that copies all of it.
/// The setting shows folded onto one line (`{"mcpServers": {"mindtalk": …`); the copy is
/// the whole text, laid out as it was. Used on the card and on the help page alike.
struct MCPCopyField: View {
    let text: String
    /// For the log: "the Claude Code command".
    let what: String
    var onCopy: () -> Void = {}
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: 6) {
            Text(verbatim: Self.oneLine(text))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? DS.Colors.ink : DS.Colors.muted)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? String(localized: "Kopierat") : String(localized: "Kopiera"))
            .accessibilityLabel(copied ? String(localized: "Kopierat") : String(localized: "Kopiera"))
        }
        .padding(.leading, 11).padding(.trailing, 4)
        .frame(height: 30)
        .background(shape.fill(DS.Colors.field))
        .overlay(shape.strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
    }

    private func copy() {
        ClaudeInstall.copy(text, what: what)
        onCopy()
        withAnimation(.snappy) { copied = true }
        copiedTask?.cancel()
        copiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { withAnimation(.snappy) { copied = false } }
        }
    }

    /// The text on one line: each line trimmed and joined with a space, braces closed
    /// up, as `{"mcpServers": {"mindtalk": {"command": …}}}`.
    static func oneLine(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .replacingOccurrences(of: "{ ", with: "{")
            .replacingOccurrences(of: " }", with: "}")
    }
}

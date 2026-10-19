import AppKit
import Foundation
import os

// MARK: - Integrationer → MCP: getting the connection into the program the user picks
//
// The settings card has a picker of programs (ClaudeInstall.Client) and one button
// whose action depends on the pick:
//
//   • Claude: a .mcpb bundle (a zip with manifest.json at its root, the Claude desktop
//     app's extension format) that Mindtalk writes and opens. The Claude app registers
//     the .mcpb type and shows the extension for installation.
//   • Claude Code, Codex, Gemini CLI: one `… mcp add` line, copied to the clipboard.
//   • Cursor, VS Code, LM Studio, Raycast: a link in the program's own scheme that
//     opens it with the server filled in.
//   • Zed and any other program: the settings snippet, copied to the clipboard.
//
// Besides that, "Installera kommandot" puts `mindtalk` in /usr/local/bin, so the same
// helper answers in the Terminal (`mindtalk meetings`, `mindtalk search …`).
//
// All point at the helper through its fixed path under Application Support
// (`~/Library/Application Support/Mindtalk/bin/mindtalk`, a link the app refreshes at
// every start), never at the app bundle itself. So the bundle holds no binary, is a
// few hundred bytes, and keeps working when the app is moved or updated. (Bear's
// users lost their connection whenever the app moved; this is why.)

enum ClaudeInstall {
    private static let log = Logger(subsystem: "ai.mindact.mindtalk", category: "Claude")

    /// The fixed path the helper is reached through. Computed here on its own, so the
    /// settings card never depends on the bridge: the bridge keeps the link at the same
    /// path.
    static var helperLinkURL: URL {
        supportDirectory.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("mindtalk")
    }

    /// `~/Library/Application Support/Mindtalk`, where the bundle and the link live.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mindtalk", isDirectory: true)
    }

    /// Where the .mcpb is written: a steady place, so Claude can be pointed at it again.
    static var bundleURL: URL { supportDirectory.appendingPathComponent("Mindtalk.mcpb") }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
    }

    /// The Claude desktop app's bundle identifier (claude.ai/download).
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static var claudeAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) }

    // MARK: The bundle

    /// The manifest, as the Claude app reads it (manifest_version 0.2, server type
    /// "binary"). `entry_point` and `mcp_config.command` are the helper's fixed path;
    /// nothing is packed into the bundle itself.
    static func manifest(helperPath: String = helperLinkURL.path, version: String = appVersion) -> [String: Any] {
        [
            "manifest_version": "0.2",
            "name": "mindtalk",
            "display_name": "Mindtalk",
            "version": version,
            "description": "Your meetings and thoughts from Mindtalk, read only when you ask. Audio and voiceprints are never shared.",
            "long_description": "Ask about one meeting, a folder or all your meetings: summaries, decisions, tasks and, if you allow it, the whole text. You decide in Mindtalk, under Settings → Integrations → MCP, what may be read and which folders stay private, and Mindtalk keeps a log of every call.",
            "author": ["name": "Mindact Solutions AB"],
            "homepage": "https://mindact.ai",
            "icon": "icon.png",
            "server": [
                "type": "binary",
                "entry_point": helperPath,
                "mcp_config": [
                    "command": helperPath,
                    "args": ["mcp"],
                ],
            ],
            "keywords": ["meetings", "notes", "transcripts", "möten", "tankar"],
            "compatibility": ["platforms": ["darwin"]],
        ]
    }

    /// The manifest as JSON text (keys in order, so two runs give the same bytes).
    static func manifestJSON(helperPath: String = helperLinkURL.path, version: String = appVersion) throws -> Data {
        try JSONSerialization.data(withJSONObject: manifest(helperPath: helperPath, version: version),
                                   options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    enum BundleError: LocalizedError {
        case zipFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .zipFailed(let code): return "ditto avslutades med kod \(code)"
            }
        }
    }

    /// Writes `Mindtalk.mcpb` and returns where it is. The zip is made by `ditto`
    /// (ships with macOS); the files are laid out in a temporary folder first.
    @discardableResult
    static func buildBundle(at destination: URL = bundleURL) throws -> URL {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Mindtalk-mcpb-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try manifestJSON().write(to: staging.appendingPathComponent("manifest.json"))
        // The app icon, so the extension is recognisable in Claude's list.
        if let icon = iconPNG() { try icon.write(to: staging.appendingPathComponent("icon.png")) }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -c -k: a PKZip archive; --norsrc leaves resource forks and Finder
        // information out, so the zip holds only our two files (no __MACOSX folder).
        ditto.arguments = ["-c", "-k", "--norsrc", staging.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw BundleError.zipFailed(ditto.terminationStatus) }
        // Yours alone, like the socket and the log.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        log.notice("wrote \(destination.lastPathComponent, privacy: .public) for \(helperLinkURL.path, privacy: .public)")
        return destination
    }

    /// The app icon at 128 pt, as PNG, for the bundle.
    private static func iconPNG() -> Data? {
        let image = NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let size = NSSize(width: 128, height: 128)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Lägg till i Claude

    enum Outcome: Equatable {
        /// The bundle is open in the Claude app, which asks to install it.
        case opened
        /// No Claude app on this Mac.
        case noClaudeApp
        /// Writing or opening failed, said in words.
        case failed(String)
    }

    /// Builds the bundle and hands it to the Claude app.
    @MainActor
    static func addToClaude() -> Outcome {
        guard let app = claudeAppURL else {
            log.notice("add to Claude: the Claude app was not found")
            return .noClaudeApp
        }
        do {
            let bundle = try buildBundle()
            // Opened in the Claude app explicitly, not through the file's type: another
            // program could have claimed .mcpb, and the bundle is meant for Claude.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([bundle], withApplicationAt: app, configuration: configuration) { _, error in
                if let error { log.error("open in Claude: \(error.localizedDescription, privacy: .public)") }
            }
            return .opened
        } catch {
            log.error("add to Claude: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: The programs

    /// The programs the card offers, in the order of the picker. `rawValue` is saved
    /// as the pick and matched against the log's client names (Bridge.peerName).
    enum Client: String, CaseIterable, Identifiable {
        case claude = "Claude"
        case claudeCode = "Claude Code"
        case codex = "ChatGPT (Codex)"
        case cursor = "Cursor"
        case vscode = "VS Code"
        case zed = "Zed"
        case gemini = "Gemini CLI"
        case lmStudio = "LM Studio"
        case raycast = "Raycast"
        case other = "Annat program"
        var id: String { rawValue }

        var title: String {
            self == .other ? String(localized: "Annat program") : rawValue
        }

        /// The program as the log names it, when the bridge could tell: the app's name
        /// from its bundle, or the executable's.
        static func matching(logName: String) -> Client? {
            // The Claude app is "Claude" (from Claude.app); Claude Code runs as a bare
            // executable, "claude".
            if logName == "claude" { return .claudeCode }
            switch logName.lowercased() {
            case "claude": return .claude
            case "claude code", "claude-code": return .claudeCode
            case "chatgpt", "codex": return .codex
            case "cursor": return .cursor
            case "code", "visual studio code", "visual studio code - insiders": return .vscode
            case "zed": return .zed
            case "gemini": return .gemini
            case "lm studio", "lmstudio": return .lmStudio
            case "raycast": return .raycast
            default: return nil
            }
        }

        /// What the one button does.
        enum Action: Equatable {
            /// The .mcpb bundle, opened in the Claude app.
            case addToClaude
            /// Text to the clipboard: the button's title and what is copied.
            case copy(title: String, text: String)
            /// A link in the program's scheme: the button's title and the link.
            case open(title: String, url: URL)
        }

        var action: Action {
            switch self {
            case .claude:
                return .addToClaude
            case .claudeCode:
                return .copy(title: String(localized: "Kopiera kommandot"), text: ClaudeInstall.claudeCodeCommand())
            case .codex:
                return .copy(title: String(localized: "Kopiera kommandot"), text: ClaudeInstall.codexCommand())
            case .gemini:
                return .copy(title: String(localized: "Kopiera kommandot"), text: ClaudeInstall.geminiCommand())
            case .zed:
                return .copy(title: String(localized: "Kopiera inställningen"), text: ClaudeInstall.zedConfig())
            case .other:
                return .copy(title: String(localized: "Kopiera inställningen"), text: ClaudeInstall.serverConfig())
            case .cursor:
                return .open(title: String(localized: "Öppna i Cursor"), url: ClaudeInstall.cursorURL())
            case .vscode:
                return .open(title: String(localized: "Öppna i VS Code"), url: ClaudeInstall.vscodeURL())
            case .lmStudio:
                return .open(title: String(localized: "Öppna i LM Studio"), url: ClaudeInstall.lmStudioURL())
            case .raycast:
                return .open(title: String(localized: "Öppna i Raycast"), url: ClaudeInstall.raycastURL())
            }
        }

        /// One muted line under the button: what happens next.
        var hint: String {
            switch self {
            case .claude: return String(localized: "Claude-appen öppnas och frågar om du vill lägga till Mindtalk.")
            case .claudeCode: return String(localized: "Klistra in i Terminalen.")
            case .codex: return String(localized: "Klistra in i Terminalen. Gäller ChatGPT:s Codex-läge. I ChatGPT-appen: Inställningar → MCP servers → Add server, typ STDIO.")
            case .gemini: return String(localized: "Klistra in i Terminalen.")
            case .zed: return String(localized: "Klistra in i Zeds settings.json.")
            case .other: return String(localized: "Klistra in i programmets MCP-inställningar.")
            case .cursor: return String(localized: "Cursor öppnas och frågar om du vill lägga till Mindtalk.")
            case .vscode: return String(localized: "VS Code öppnas och frågar om du vill lägga till Mindtalk.")
            case .lmStudio: return String(localized: "LM Studio öppnas och frågar om du vill lägga till Mindtalk.")
            case .raycast: return String(localized: "Raycast öppnas och frågar om du vill lägga till Mindtalk.")
            }
        }

        /// "Cursor hittades inte." when the link's program isn't on this Mac.
        var notFound: String { String(localized: "\(rawValue) hittades inte.") }
    }

    // MARK: The commands

    /// The line for the Terminal: `claude mcp add --scope user mindtalk -- "<path>" mcp`.
    /// The path is quoted: Application Support has a space in it.
    static func claudeCodeCommand(helperPath: String = helperLinkURL.path) -> String {
        "claude mcp add --scope user mindtalk -- \"\(helperPath)\" mcp"
    }

    /// For ChatGPT's Codex side (the Codex CLI and the app's MCP settings share one list).
    static func codexCommand(helperPath: String = helperLinkURL.path) -> String {
        "codex mcp add mindtalk -- \"\(helperPath)\" mcp"
    }

    static func geminiCommand(helperPath: String = helperLinkURL.path) -> String {
        "gemini mcp add --scope user mindtalk \"\(helperPath)\" mcp"
    }

    @MainActor
    static func copyClaudeCodeCommand() { copy(claudeCodeCommand(), what: "the Claude Code command") }

    @MainActor
    static func copy(_ text: String, what: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        log.notice("copied \(what, privacy: .public)")
    }

    // MARK: The settings

    /// The path as a JSON string, quoted.
    static func jsonPath(_ helperPath: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(helperPath)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(helperPath)\""
    }

    /// The `mcpServers` snippet most MCP clients accept in their settings:
    ///
    ///     { "mcpServers": { "mindtalk": { "command": "<path>", "args": ["mcp"] } } }
    ///
    /// Laid out by hand, `command` before `args` and no space before the colons, so it
    /// reads like the examples in every client's documentation. Only the path is run
    /// through the encoder, for the quoting.
    static func serverConfig(helperPath: String = helperLinkURL.path) -> String {
        """
        {
          "mcpServers": {
            "mindtalk": {
              "command": \(jsonPath(helperPath)),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    /// Zed keeps its servers under `context_servers` in settings.json.
    static func zedConfig(helperPath: String = helperLinkURL.path) -> String {
        """
        "context_servers": {
          "mindtalk": {
            "command": \(jsonPath(helperPath)),
            "args": ["mcp"],
            "env": {}
          }
        }
        """
    }

    @MainActor
    static func copyServerConfig() { copy(serverConfig(), what: "the MCP server config") }

    // MARK: The links

    /// `{"command":"<path>","args":["mcp"]}`, the one server, compact.
    static func serverJSON(helperPath: String = helperLinkURL.path) -> String {
        "{\"command\":\(jsonPath(helperPath)),\"args\":[\"mcp\"]}"
    }

    /// Cursor: name and the server as base64 (cursor.com/docs/context/mcp, "Install link").
    static func cursorURL(helperPath: String = helperLinkURL.path) -> URL {
        let config = Data(serverJSON(helperPath: helperPath).utf8).base64EncodedString()
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=mindtalk&config=\(config)")!
    }

    /// VS Code: the server with its name, percent-encoded, after `vscode:mcp/install?`.
    static func vscodeURL(helperPath: String = helperLinkURL.path) -> URL {
        let json = "{\"name\":\"mindtalk\",\"command\":\(jsonPath(helperPath)),\"args\":[\"mcp\"]}"
        return URL(string: "vscode:mcp/install?\(percent(json))")!
    }

    /// LM Studio: like Cursor's, in its own scheme.
    static func lmStudioURL(helperPath: String = helperLinkURL.path) -> URL {
        let config = Data(serverJSON(helperPath: helperPath).utf8).base64EncodedString()
        return URL(string: "lmstudio://add_mcp?name=mindtalk&config=\(config)")!
    }

    /// Raycast: the whole `mcpServers` object, percent-encoded.
    static func raycastURL(helperPath: String = helperLinkURL.path) -> URL {
        let json = "{\"mcpServers\":{\"mindtalk\":\(serverJSON(helperPath: helperPath))}}"
        return URL(string: "raycast://mcp/install?\(percent(json))")!
    }

    /// Everything but letters, digits and `-._~` escaped, so braces, quotes, slashes
    /// and spaces all survive the trip through the scheme.
    private static func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? text
    }

    enum OpenOutcome: Equatable {
        case opened
        /// No program on this Mac claims the link's scheme.
        case notInstalled
    }

    /// Opens the link in the program that owns its scheme, if there is one.
    @MainActor
    static func open(_ url: URL) -> OpenOutcome {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            log.notice("no app for \(url.scheme ?? "", privacy: .public)://")
            return .notInstalled
        }
        NSWorkspace.shared.open(url)
        log.notice("opened \(url.scheme ?? "", privacy: .public):// link")
        return .opened
    }

    // MARK: Terminalen: /usr/local/bin/mindtalk

    /// Where the command goes: on every Mac's PATH, and where Homebrew, Docker and
    /// the editors put theirs.
    static let commandURL = URL(fileURLWithPath: "/usr/local/bin/mindtalk")

    /// The command is there and is ours (a link to the fixed path).
    static var commandInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: commandURL.path)) == helperLinkURL.path
    }

    enum CommandError: LocalizedError, Equatable {
        /// The owner pressed Avbryt in the password prompt.
        case cancelled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return String(localized: "Avbrutet.")
            case .failed(let why): return why
            }
        }
    }

    /// Puts the link in place (or takes it away), with the system's password prompt:
    /// /usr/local/bin belongs to root. `do shell script … with administrator
    /// privileges`, as Obsidian and others do it; the command itself is a `ln` or `rm`.
    @MainActor
    static func installCommand() -> Result<Void, CommandError> {
        asAdministrator("/bin/mkdir -p /usr/local/bin && /bin/ln -sfn \(shellQuoted(helperLinkURL.path)) \(shellQuoted(commandURL.path))")
    }

    @MainActor
    static func removeCommand() -> Result<Void, CommandError> {
        asAdministrator("/bin/rm -f \(shellQuoted(commandURL.path))")
    }

    /// Single quotes, with any quote inside closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The AppleScript line for a shell command, the command escaped as an AppleScript string.
    static func administratorScript(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    @MainActor
    private static func asAdministrator(_ command: String) -> Result<Void, CommandError> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: administratorScript(command)) else { return .failure(.failed("NSAppleScript")) }
        script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(code)"
            // -128: the user pressed Cancel.
            if code == -128 { log.notice("command: cancelled"); return .failure(.cancelled) }
            log.error("command: \(message, privacy: .public)")
            return .failure(.failed(message))
        }
        log.notice("command: ran \(command, privacy: .public)")
        return .success(())
    }

    static let downloadURL = URL(string: "https://claude.ai/download")!
}

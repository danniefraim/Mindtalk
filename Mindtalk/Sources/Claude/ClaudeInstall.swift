import AppKit
import Foundation
import os

// MARK: - Integrationer → MCP: getting the connection into the program the user picks
//
// Three ways in, all from the settings card:
//
//   • "Lägg till i Claude": a .mcpb bundle (a zip with manifest.json at its root, the
//     Claude desktop app's extension format) that Mindtalk writes and opens. The Claude
//     app registers the .mcpb type and shows the extension for installation.
//   • "Kopiera för Claude Code": one `claude mcp add` line, copied to the clipboard.
//   • "Kopiera för andra program": the `mcpServers` JSON snippet most MCP clients
//     (ChatGPT on Mac, Cursor, Zed and others) accept, copied to the clipboard.
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
            "long_description": "Ask about one meeting, a folder or all your meetings: summaries, decisions, tasks and, if you allow it, the whole text. Mindtalk decides what may be read, in Inställningar → Integrationer → MCP, and keeps a log of every call.",
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

    // MARK: Kopiera för Claude Code

    /// The line for the Terminal: `claude mcp add --scope user mindtalk -- "<path>" mcp`.
    /// The path is quoted: Application Support has a space in it.
    static func claudeCodeCommand(helperPath: String = helperLinkURL.path) -> String {
        "claude mcp add --scope user mindtalk -- \"\(helperPath)\" mcp"
    }

    @MainActor
    static func copyClaudeCodeCommand() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(claudeCodeCommand(), forType: .string)
        log.notice("copied the Claude Code command")
    }

    // MARK: Kopiera för andra program

    /// The `mcpServers` snippet most MCP clients accept in their settings (ChatGPT on
    /// Mac, Cursor, Zed, Claude Code's own JSON and others):
    ///
    ///     { "mcpServers": { "mindtalk": { "command": "<path>", "args": ["mcp"] } } }
    ///
    /// Laid out by hand, `command` before `args` and no space before the colons, so it
    /// reads like the examples in every client's documentation. Only the path is run
    /// through the encoder, for the quoting.
    static func serverConfig(helperPath: String = helperLinkURL.path) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = (try? encoder.encode(helperPath)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\(helperPath)\""
        return """
        {
          "mcpServers": {
            "mindtalk": {
              "command": \(path),
              "args": ["mcp"]
            }
          }
        }
        """
    }

    @MainActor
    static func copyServerConfig() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(serverConfig(), forType: .string)
        log.notice("copied the MCP server config")
    }

    static let downloadURL = URL(string: "https://claude.ai/download")!
}

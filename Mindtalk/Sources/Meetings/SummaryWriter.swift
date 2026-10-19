import Foundation
import FoundationModels

// MARK: - Who writes the summaries
//
// Three can write a meeting's summary and answer questions about it: Apple
// Intelligence (built in), a Gemma 4 downloaded into Mindtalk, or your own model
// running in Ollama or LM Studio on this Mac. Each is a `SummaryWriter`: given
// instructions and a prompt, it writes plain text. The notes code reads that text
// the same way whoever wrote it, and checks every source it names.
//
// The shape is kept close to what Apple showed for macOS 27 (a LanguageModelExecutor
// that answers a session's prompts), so a writer can become one then without
// rebuilding the notes.

protocol SummaryWriter: Sendable {
    /// "Gemma 4 E4B", "Ollama · qwen3.5:9b".
    var name: String { get }
    /// How much it reads at once, in tokens.
    var contextTokens: Int { get }
    /// Words of transcript per part, with room left for instructions and the answer.
    var wordBudget: Int { get }
    /// An answer that names no line it came from isn't shown.
    var requiresSources: Bool { get }
    /// One answer: `system` says how to write, `user` is what to write about.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    /// After a summary: let go of what can be let go.
    func finished() async
}

extension SummaryWriter {
    var requiresSources: Bool { false }
    func finished() async {}
}

/// Which one is chosen, as kept in the settings.
enum SummaryWriterChoice: Equatable, Sendable {
    case apple
    case gemma(NotesModel)
    case server(ServerBackend, String)

    /// "apple", "gemma:e4b", "server:ollama:qwen3.5:9b".
    var stored: String {
        switch self {
        case .apple: return "apple"
        case .gemma(let m): return "gemma:\(m.rawValue)"
        case .server(let b, let model): return "server:\(b.rawValue):\(model)"
        }
    }

    init?(stored: String) {
        if stored == "apple" { self = .apple; return }
        let parts = stored.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "gemma": guard parts.count == 2, let m = NotesModel(rawValue: parts[1]) else { return nil }; self = .gemma(m)
        case "server":
            guard parts.count == 3, let b = ServerBackend(rawValue: parts[1]), !parts[2].isEmpty else { return nil }
            self = .server(b, parts[2])
        default: return nil
        }
    }

    var isServer: Bool { if case .server = self { return true }; return false }
}

/// Apple Intelligence as a writer of plain text. The notes mostly ask Apple's model
/// for structured answers (MeetingNotes); this is for the plain-text turns.
struct AppleWriter: SummaryWriter {
    let name = "Apple Intelligence"
    let contextTokens = 4_096
    let wordBudget = Lines.appleBudget

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = system.isEmpty ? LanguageModelSession(model: model) : LanguageModelSession(model: model, instructions: system)
        return try await session.respond(to: user, options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)).content
    }
}

/// A Gemma 4 downloaded into Mindtalk, run through MLX (BetterNotes.swift).
struct GemmaWriter: SummaryWriter {
    let model: NotesModel
    var name: String { model.name }
    let contextTokens = 131_072
    let wordBudget = Lines.localBudget

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await LocalWriter.shared.respond(system.isEmpty ? user : system + "\n\n" + user, maxTokens: maxTokens)
    }
}

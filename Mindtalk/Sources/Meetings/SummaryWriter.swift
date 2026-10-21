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
    /// The name in a sentence: "qwen3.5:9b i Ollama" (the same as `name` for the rest).
    var sentenceName: String { get }
    /// How much it reads at once, in tokens.
    var contextTokens: Int { get }
    /// Words of transcript per part, with room left for instructions and the answer.
    var wordBudget: Int { get }
    /// An answer that names no line it came from isn't shown.
    var requiresSources: Bool { get }
    /// A job of several parts (a summary): what they are, before the first, so a writer
    /// can make itself ready once for all of them.
    func begin(system: String, prompts: [String]) async throws
    /// One answer: `system` says how to write, `user` is what to write about.
    func complete(system: String, user: String, maxTokens: Int) async throws -> String
    /// After a summary: let go of what can be let go.
    func finished() async
}

extension SummaryWriter {
    var sentenceName: String { name }
    var requiresSources: Bool { false }
    func begin(system: String, prompts: [String]) async throws {}
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

    /// The writer it names, unless it's Apple Intelligence (nil). The one named,
    /// whether it can write right now or not: a Gemma moved to the Trash, or a server
    /// that isn't running, says so when asked to write. Never another writer instead.
    @MainActor var writer: (any SummaryWriter)? {
        switch self {
        case .apple: return nil
        case .gemma(let m): return GemmaWriter(model: m)
        case .server(let b, let m): return LocalServerWriter(backend: b, model: m)
        }
    }
    /// "Gemma 4 E4B", "Ollama · qwen3.5:9b", or "Apple Intelligence".
    @MainActor var name: String { writer?.name ?? "Apple Intelligence" }
    /// The same in a sentence: "qwen3.5:9b i Ollama".
    @MainActor var sentenceName: String { writer?.sentenceName ?? "Apple Intelligence" }

    #if DEBUG
    /// `Mindtalk --writer-test`: every choice through `stored` and back, including
    /// server models whose ids have "/" and ":" in them, and strings that must not parse.
    static func selfTest() -> Int32 {
        var failed = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failed += 1; print("FEL  \(what)") } }
        var choices: [SummaryWriterChoice] = [.apple]
        choices += NotesModel.allCases.map { .gemma($0) }
        let ids = ["qwen3.5:9b", "google/gemma-4-e4b", "hf.co/unsloth/gemma-3:latest",
                   "lmstudio-community/gemma-4-E4B-it-MLX-4bit", "a:b:c/d:e", "mistral"]
        for b in ServerBackend.allCases { for id in ids { choices.append(.server(b, id)) } }
        for c in choices {
            let back = SummaryWriterChoice(stored: c.stored)
            check(back == c, "\(c.stored) läses tillbaka som \(back.map(\.stored) ?? "ingenting")")
        }
        check(SummaryWriterChoice(stored: "server:lmStudio:google/gemma-4-e4b") == .server(.lmStudio, "google/gemma-4-e4b"), "LM Studio-modellen som den sparas")
        check(SummaryWriterChoice(stored: "server:ollama:qwen3.5:9b") == .server(.ollama, "qwen3.5:9b"), "Ollama-modellen som den sparas")
        check(SummaryWriterChoice(stored: "gemma:e4b") == .gemma(.small), "gemma:e4b")
        for bad in ["", "apple:", "gemma", "gemma:", "gemma:x", "server", "server:", "server:ollama", "server:ollama:", "server:nope:m", "ollama:qwen3.5:9b"] {
            check(SummaryWriterChoice(stored: bad) == nil, "\"\(bad)\" ska inte läsas som ett val")
        }
        print(failed == 0 ? "Writer self-test passed (\(choices.count) val)." : "\(failed) fel")
        return failed == 0 ? 0 : 1
    }
    #endif
}

/// A chosen writer that can't write right now, said plainly.
enum WriterError: Error, Equatable {
    /// The Gemma chosen is no longer on the disk (moved to the Trash in Finder).
    case gemmaMissing(NotesModel)
    /// The Gemma chosen is still being downloaded.
    case gemmaDownloading(NotesModel)

    var plainWords: String {
        switch self {
        case .gemmaMissing(let m):
            return String(localized: "\(m.name) finns inte kvar på disken. Ladda ned den igen under Inställningar → Sammanfattningar, eller välj en annan där.")
        case .gemmaDownloading(let m):
            return String(localized: "\(m.name) laddas fortfarande ned. Sammanfatta igen när den är klar.")
        }
    }
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

    /// The Gemma chosen writes, or says why it can't: never another writer instead.
    private func ready() async throws {
        guard !model.isInstalled else { return }
        if case .downloading = await MainActor.run(body: { BetterNotes.shared.state(model) }) { throw WriterError.gemmaDownloading(model) }
        throw WriterError.gemmaMissing(model)
    }

    func begin(system: String, prompts: [String]) async throws { try await ready() }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await ready()
        return try await LocalWriter.shared.respond(system.isEmpty ? user : system + "\n\n" + user, model: model, maxTokens: maxTokens)
    }
}

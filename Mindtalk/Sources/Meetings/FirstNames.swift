import Foundation

/// First names people in Sweden have (Statistics Sweden, 2020: every name at least
/// twenty people carry — scripts/first-names.py). A word said on its own in the round
/// must be one of them — or a word in your Ordlista, or a voice you've named — to be
/// taken as a name.
@MainActor
enum FirstNames {
    private static let all: Set<String> = {
        guard let url = Bundle.main.url(forResource: "FirstNames", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    static func isName(_ word: String) -> Bool {
        let lower = word.lowercased()
        return all.contains(lower)
            || Vocabulary.shared.entries.contains { $0.word.lowercased() == lower }
            || VoiceMemory.shared.people.contains { $0.name.split(separator: " ").first?.lowercased() == lower }
    }
}

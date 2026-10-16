import SwiftUI

// MARK: - What's worth downloading
//
// Everything Mindtalk can fetch is offered where it helps — and gathered here, at the
// top of Inställningar → Modeller: what's missing, what it gives you, and one button.
// Only what fits on the disk is suggested; nothing is fetched without a click.

struct RecommendedDownloads: View {
    @ObservedObject private var voices = VoiceModels.shared
    @ObservedObject private var notes = BetterNotes.shared
    @ObservedObject private var listener = VocabularyBoostStatus.shared
    @ObservedObject private var vocabulary = Vocabulary.shared

    struct Item: Identifiable {
        let id: String
        let name: String
        let gives: String
        let bytes: Int64
        let start: () -> Void
    }

    /// Missing and useful, in the order they matter — as many as fit with room to spare.
    private var items: [Item] {
        var all: [Item] = []
        if voices.state == .missing {
            all.append(Item(id: "voices", name: "Nemotron 3", gives: String(localized: "Vem som säger vad i möten"),
                            bytes: 400_000_000, start: { VoiceModels.shared.download() }))
        }
        if listener.state == .missing, vocabulary.hasOwnWords {
            all.append(Item(id: "listener", name: String(localized: "Lyssnaren"),
                            gives: String(localized: "Dina ord stavas rätt redan när du pratar"),
                            bytes: 100_000_000, start: { Vocabulary.shared.allowListener() }))
        }
        var room = BetterNotes.freeBytes - 2_000_000_000
        // The best Gemma this Mac runs that also fits next to the rest — the large one
        // when there's room, the small one when there isn't.
        let rest = all.reduce(Int64(0)) { $0 + $1.bytes }
        if notes.active == nil,
           let m = NotesModel.allCases.reversed().first(where: { m in
               guard m.supported, case .missing = notes.state(m) else { return false }
               return m.remainingBytes + rest <= room
           }) {
            all.append(Item(id: "notes", name: m.name, gives: String(localized: "Mer träffsäkra sammanfattningar"),
                            bytes: m.remainingBytes, start: { BetterNotes.shared.download(m) }))
        }
        return all.filter { item in
            guard item.bytes <= room else { return false }
            room -= item.bytes
            return true
        }
    }

    var body: some View {
        let items = items
        if !items.isEmpty {
            let total = items.reduce(Int64(0)) { $0 + $1.bytes }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                    Text("Rekommenderas för din Mac").font(.system(size: 14, weight: .semibold))
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.name).font(.system(size: 13, weight: .medium))
                            Text(item.gives).font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                            Spacer(minLength: 8)
                            Text(Self.size(item.bytes)).font(.system(size: 12)).monospacedDigit()
                                .foregroundStyle(DS.Colors.muted)
                        }
                    }
                }
                // The larger Gemma, when this Mac runs it but it doesn't fit: said, not offered.
                if let best = NotesModel.recommended, notes.active == nil, !best.hasRoom,
                   items.contains(where: { $0.id == "notes" }) {
                    Text("Den större \(best.name) passar också din Mac men behöver \(BetterNotes.gigabytes(best.remainingBytes + 2_000_000_000)) ledigt.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                }
                HStack(spacing: 10) {
                    Text("Laddas ned en gång och körs på din Mac. Du har \(BetterNotes.gigabytes(BetterNotes.freeBytes)) ledigt.")
                        .font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    Spacer()
                    Button(items.count == 1 ? String(localized: "Ladda ned \(Self.size(total))")
                                            : String(localized: "Ladda ned allt · \(Self.size(total))")) {
                        for item in items { item.start() }
                    }
                    .buttonStyle(.ink)
                }
            }
            .padding(18)
            .card()
            .transition(.opacity)
        }
    }
}

extension RecommendedDownloads {
    /// "100 MB" under a gigabyte, "6,9 GB" above.
    static func size(_ bytes: Int64) -> String {
        bytes < 1_000_000_000 ? "\(bytes / 1_000_000) MB" : BetterNotes.gigabytes(bytes)
    }
}

// MARK: - The listener, offered where it helps

/// On Ordlista, once there are words of your own and no listener yet: what it gives,
/// how big it is, and a yes or a not now (asked once).
struct ListenerOffer: View {
    @ObservedObject private var listener = VocabularyBoostStatus.shared
    @ObservedObject private var vocabulary = Vocabulary.shared
    @AppStorage("listenerOfferAnswered") private var answered = false

    var body: some View {
        if vocabulary.hasOwnWords, !answered || listener.state == .downloading {
            switch listener.state {
            case .missing where !Settings.listenerAllowed:
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "ear").font(.system(size: 15)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stava rätt redan när du pratar").font(.system(size: 14, weight: .semibold))
                            Text("I dag rättas dina ord i texten efteråt. Med lyssnaren hör Mindtalk dem direkt – också namn som låter som vanliga ord. Den laddas ned en gång (\(VocabularyBoost.sizeText)) och körs på din Mac.")
                                .font(.system(size: 13)).foregroundStyle(DS.Colors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    HStack(spacing: 10) {
                        Spacer()
                        Button("Inte nu") { withAnimation(.snappy) { answered = true } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                        Button("Ladda ned \(VocabularyBoost.sizeText)") {
                            answered = true
                            Vocabulary.shared.allowListener()
                        }
                        .buttonStyle(.ink)
                    }
                }
                .padding(18)
                .card()
                .transition(.opacity)
            case .downloading:
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Laddar ned lyssnaren…").font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(16)
                .card()
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }
}

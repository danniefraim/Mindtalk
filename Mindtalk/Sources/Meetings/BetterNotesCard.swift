import SwiftUI

/// Settings → Möten: the optional, larger notes model — offered where it runs well,
/// with its size and what it needs said up front.
struct BetterNotesCard: View {
    @ObservedObject var notes: BetterNotes
    @State private var confirmRemove = false

    var body: some View {
        VStack(spacing: 0) {
            CardRow(title: "Bättre sammanfattningar", detail: detail) { control }
            if case .downloading(let p) = notes.state {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p).tint(DS.Colors.ink)
                    Text(progressText(p)).font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.Colors.muted)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
            }
            if notes.state == .ready {
                CardDivider()
                CardRow(title: "Gemma 4 på den här Macen",
                        detail: String(localized: "\(BetterNotes.sizeText) på disken. Ta bort den för att frigöra plats – Apple Intelligence tar över.")) {
                    Button("Ta bort…") { confirmRemove = true }.buttonStyle(.soft)
                }
            }
        }
        .card()
        .confirmationDialog("Ta bort Gemma 4?", isPresented: $confirmRemove) {
            Button("Ta bort", role: .destructive) { notes.remove() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Sammanfattningarna skrivs med Apple Intelligence igen. Du kan ladda ned Gemma 4 när du vill.")
        }
    }

    private var detail: String {
        switch notes.state {
        case .unsupported:
            return String(localized: "Gemma 4 från Google skriver djupare sammanfattningar och svar, men kräver minst \(BetterNotes.minimumMemoryGB) GB minne. Den här Macen har \(BetterNotes.memoryGB) GB, så Apple Intelligence skriver sammanfattningarna.")
        case .missing, .failed:
            var text = String(localized: "Gemma 4 från Google skriver sammanfattningarna och svarar på frågor – mer träffsäkert än Apple Intelligence och utan ämnesspärrar. Laddas ned en gång (\(BetterNotes.sizeText)) och fungerar sedan utan internet.")
            if !BetterNotes.hasRoom {
                text += " " + String(localized: "Det behövs drygt \(BetterNotes.sizeText) ledigt på disken – du har \(BetterNotes.freeBytes / 1_000_000_000) GB.")
            }
            if case .failed(let message) = notes.state { text += " " + message }
            return text
        case .downloading:
            return String(localized: "Laddar ned Gemma 4 från Google. Du kan fortsätta använda Mindtalk under tiden.")
        case .ready:
            return notes.enabled
                ? String(localized: "Gemma 4 skriver mötenas sammanfattningar och svarar på frågor.")
                : String(localized: "Av. Apple Intelligence skriver sammanfattningarna.")
        }
    }

    @ViewBuilder private var control: some View {
        switch notes.state {
        case .unsupported:
            EmptyView()
        case .missing where Self.partly:
            Button("Fortsätt – \(Self.leftText) kvar") { notes.download() }
                .buttonStyle(.ink)
                .disabled(!BetterNotes.hasRoom)
        case .missing:
            Button("Ladda ned \(BetterNotes.sizeText)") { notes.download() }
                .buttonStyle(.ink)
                .disabled(!BetterNotes.hasRoom)
        case .failed:
            Button(Self.partly ? "Fortsätt" : "Försök igen") { notes.download() }.buttonStyle(.soft).disabled(!BetterNotes.hasRoom)
        case .downloading:
            Button("Avbryt") { notes.cancel() }.buttonStyle(.soft)
        case .ready:
            InkToggle(label: "Bättre sammanfattningar", isOn: $notes.enabled)
        }
    }

    /// An earlier download got part of the way: it continues from there.
    private static var partly: Bool { BetterNotes.remainingBytes < BetterNotes.bytes - 50_000_000 }
    private static var leftText: String {
        String(format: "%.1f GB", Double(BetterNotes.remainingBytes) / 1e9).replacingOccurrences(of: ".", with: ",")
    }

    private func progressText(_ p: Double) -> String {
        let total = Double(BetterNotes.bytes) / 1e9
        var text = String(format: "%.1f av %.1f GB", p * total, total).replacingOccurrences(of: ".", with: ",")
        // Measured from where this try began — a continued download starts part way.
        if let started = notes.downloadStarted, let base = notes.downloadBase, p - base > 0.02 {
            let elapsed = Date().timeIntervalSince(started)
            let left = elapsed * (1 - p) / (p - base)
            if left >= 60 { text += " · " + String(localized: "ca \(Int((left / 60).rounded())) min kvar") }
        }
        return text
    }
}

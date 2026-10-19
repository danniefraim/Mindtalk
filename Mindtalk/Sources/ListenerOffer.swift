import SwiftUI

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
                            Text("Rätt stavat redan när du pratar").font(.system(size: 14, weight: .semibold))
                            Text("I dag rättas dina ord i texten efteråt. Med lyssnaren hör Mindtalk dem direkt, också namn som låter som vanliga ord. Den laddas ned en gång (\(VocabularyBoost.sizeText)) och körs på din Mac.")
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

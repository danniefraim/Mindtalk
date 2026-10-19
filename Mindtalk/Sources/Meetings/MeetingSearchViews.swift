import SwiftUI

// MARK: - Search and ask, on the Möten page
//
// A search field over the list: as you type, the list becomes the meetings that
// hold the words, each with where — the sentence, who said it, the moment. And a
// question field at the bottom, as inside a meeting, but for all of them; the
// answers stay above the list with the meetings and moments they come from.

/// "Sök i mötena" — ⌘F.
struct LibrarySearchField: View {
    @Binding var query: String
    /// A folder chosen: the search is in it.
    var folder: String? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            TextField(folder.map { String(localized: "Sök i \($0)") } ?? String(localized: "Sök i mötena"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onExitCommand { query = "" }
                .accessibilityLabel(folder.map { String(localized: "Sök i \($0)") } ?? String(localized: "Sök i mötena"))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(DS.Colors.faint)
                }
                .buttonStyle(.plain)
                .help("Rensa")
                .accessibilityLabel("Rensa sökningen")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .strokeBorder(focused ? DS.Colors.ink.opacity(0.5) : DS.Colors.fieldStroke, lineWidth: 1))
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
    }
}

/// The meetings a search found, each with where.
struct SearchResults: View {
    let matches: [MeetingMatch]
    let query: String
    /// Searched in a folder: said so, with the way to search them all.
    var folder: String? = nil
    var showAll: (() -> Void)? = nil
    let open: (UUID, Double?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(matches.isEmpty
                     ? (folder.map { String(localized: "Inget möte i \($0) innehåller det.") } ?? String(localized: "Inget möte innehåller det."))
                     : matches.count == 1 ? String(localized: "1 möte") : String(localized: "\(matches.count) möten"))
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                if folder != nil, let showAll {
                    Button("Sök i alla möten", action: showAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                }
            }
            ForEach(matches) { match in
                VStack(alignment: .leading, spacing: 0) {
                    Button { open(match.record.id, nil) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(highlighted(match.record.title)).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 10)
                            Text(MeetingRecord.when(match.record.date)).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                            Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DS.Colors.faint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Found: dragged onto a folder, or moved from here.
                    .meetingDrag(match.record)
                    .meetingMoveActions([match.record.id])
                    .contextMenu {
                        Button("Öppna") { open(match.record.id, nil) }
                        MoveToFolderMenu(ids: [match.record.id], current: match.record.folder)
                        HideFromAIItem(record: match.record)
                    }
                    ForEach(match.hits.filter { $0.kind != .title }) { hit in
                        CardDivider()
                        HitRow(hit: hit, text: highlighted(hit.text)) { open(match.record.id, hit.at) }
                    }
                }
                .card()
            }
        }
    }

    /// The words searched for, in bold.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for word in query.split(separator: " ").map(String.init) where word.count >= 2 {
            var from = out.startIndex
            while from < out.endIndex, let r = out[from...].range(of: word, options: .caseInsensitive) {
                out[r].inlinePresentationIntent = .stronglyEmphasized
                out[r].foregroundColor = DS.Colors.ink
                from = r.upperBound
            }
        }
        return out
    }
}

private struct HitRow: View {
    let hit: MeetingHit
    let text: AttributedString
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 11.5)).foregroundStyle(DS.Colors.faint).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    if let label { Text(label).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.Colors.muted) }
                    Text(text).font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let at = hit.at {
                    Text(MeetingView.duration(at)).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(DS.Colors.muted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(hovering ? DS.Colors.chip.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(hit.at == nil ? "Öppna mötet" : "Öppna mötet där det sades")
    }

    private var symbol: String {
        switch hit.kind {
        case .title: return "textformat"
        case .summary: return "sparkles"
        case .note: return "pencil"
        case .said: return "quote.bubble"
        }
    }

    private var label: String? {
        switch hit.kind {
        case .said: return hit.who.flatMap { $0.isEmpty ? nil : $0 }
        case .note: return String(localized: "Din anteckning")
        case .summary: return String(localized: "Sammanfattningen")
        case .title: return nil
        }
    }
}

/// The questions asked about all meetings, with where the answers come from.
struct LibraryAnswers: View {
    @ObservedObject var library: MeetingLibrary
    let open: (UUID, Double?) -> Void

    var body: some View {
        if !library.answers.isEmpty || library.asking || library.failed != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Frågor om dina möten")
                    Spacer()
                    if !library.answers.isEmpty {
                        Button("Rensa") { withAnimation(.snappy) { library.clear() } }
                            .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(library.answers.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { CardDivider() }
                        AnswerRow(answer: a, open: open) { withAnimation(.snappy) { library.forget(a) } }
                    }
                    if library.asking {
                        if !library.answers.isEmpty { CardDivider() }
                        HStack(spacing: 10) {
                            SettlingLine(color: DS.Colors.ink).scaleEffect(0.7).frame(width: 40)
                            Text("Läser dina möten…").font(.system(size: 13.5)).foregroundStyle(DS.Colors.muted)
                            Spacer()
                        }
                        .padding(16)
                    }
                    if let failed = library.failed {
                        Label(failed, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13)).foregroundStyle(DS.Colors.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .card()
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

private struct AnswerRow: View {
    let answer: LibraryAnswer
    let open: (UUID, Double?) -> Void
    let forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: header).font(.system(size: 11.5)).foregroundStyle(DS.Colors.faint)
                    Text(answer.question).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.muted)
                }
                Spacer()
                Button(action: forget) {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(DS.Colors.faint)
                }
                .buttonStyle(.plain).help("Ta bort").accessibilityLabel("Ta bort svaret")
            }
            Text(answer.answer)
                .font(.system(size: 15, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !answer.sources.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(answer.sources) { s in
                        Button { open(s.meeting, s.at) } label: {
                            HStack(spacing: 4) {
                                Text(s.title).lineLimit(1)
                                if let at = s.at { Text(MeetingView.duration(at)).monospacedDigit().foregroundStyle(DS.Colors.muted) }
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(Capsule().fill(DS.Colors.chip))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Öppna mötet där det sades")
                    }
                }
            }
        }
        .padding(16)
    }

    /// "I Kund X · Läste 3 möten", "Alla möten · Läste de 12 senaste mötena". The folder's
    /// name as it is now (renamed since: the new one; removed: the one it had).
    private var header: String {
        let folder = answer.folderID.flatMap { MeetingFolders.shared.folder($0)?.name } ?? answer.folder
        let scope = folder.map { String(localized: "I \($0)") } ?? String(localized: "Alla möten")
        let read: String? = switch answer.read {
        case 0: nil
        case 1: String(localized: "Läste 1 möte")
        case let n where (answer.total ?? 0) > n: String(localized: "Läste de \(n) senaste mötena")
        case let n: String(localized: "Läste \(n) möten")
        }
        return read.map { "\(scope) · \($0)" } ?? scope
    }
}

/// "Fråga något om dina möten…" — at the bottom of the Möten page.
struct LibraryAskBar: View {
    @ObservedObject var library: MeetingLibrary
    @ObservedObject private var folders = MeetingFolders.shared
    @State private var question = ""
    @FocusState private var focused: Bool
    private static let suggestions: [LocalizedStringResource] = ["Vad bestämdes den här veckan?", "Vilka uppgifter har jag?",
                                                                  "Vad pratade vi om i går?"]
    private var empty: Bool { question.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The pointer over the suggestions: they stay while you reach for one.
    @State private var overSuggestions = false
    /// What a question reads: the folder's meetings, or all of them.
    private var scope: String {
        folders.folder(folders.selected).map { String(localized: "Fråga om mötena i \($0.name)") }
            ?? String(localized: "Fråga om alla möten")
    }

    var body: some View {
        VStack(spacing: 10) {
            // Suggestions once you're in the field — then the list isn't covered, and
            // it's said what they ask: all your meetings, or the folder's.
            if focused || overSuggestions, library.answers.isEmpty, !library.asking, empty {
                VStack(spacing: 8) {
                Text(scope)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.Colors.muted)
                HStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.key) { s in
                        Button { ask(String(localized: s)) } label: {
                            Text(s)
                                .font(.system(size: 12.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 28)
                                .background(Capsule().fill(DS.Colors.field))
                                .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                }
                .onHover { overSuggestions = $0 }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: 10) {
                TextField(scope, text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { ask(question) }
                    .accessibilityLabel(scope)
                if !focused, empty, !library.asking {
                    Text(verbatim: "⌘K").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Colors.faint)
                        .accessibilityHidden(true)
                }
                if library.asking {
                    SettlingLine(color: DS.Colors.ink).scaleEffect(0.7).frame(width: 40)
                } else {
                    Button { ask(question) } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(empty ? DS.Colors.faint : DS.Colors.onInk)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(empty ? DS.Colors.chip : DS.Colors.ink))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .help("Skicka frågan (↩)")
                    .accessibilityLabel("Skicka frågan")
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 46)
            .background(Capsule().fill(DS.Colors.field).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
            .overlay(Capsule().strokeBorder(focused ? DS.Colors.ink : DS.Colors.fieldStroke, lineWidth: focused ? 1.5 : 1))
            .background {
                Button("") { focused = true }.keyboardShortcut("k", modifiers: .command).opacity(0).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [DS.Colors.paper.opacity(0), DS.Colors.paper], startPoint: .top, endPoint: .center))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: library.answers.isEmpty)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: focused)
    }

    private func ask(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !library.asking else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { library.ask(q) }
        question = ""
    }
}

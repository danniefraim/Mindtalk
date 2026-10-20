import SwiftUI

// MARK: - Ordlista page

struct VocabularyPage: View {
    @ObservedObject var vocabulary: Vocabulary
    /// Screenshots: without the scroll view.
    var plain = false
    /// "Lägg till i Ordlista…" on Diktering: how a word was heard, put in "Hörs ofta som"
    /// when the page opens, with the cursor in "Ord" for the right spelling.
    static var pendingHeard: String?
    @Environment(\.undoManager) private var undo
    @State private var word = ""
    @State private var heardAs = ""
    @State private var sample = ""
    @State private var search = ""
    @State private var highlighted: UUID?
    @FocusState private var wordFocused: Bool
    /// How the list is sorted — remembered.
    @AppStorage("vocabularySort") private var sort = Sort.newest.rawValue
    /// Hints in the two fields, set by an example chip.
    @State private var example = String(localized: "t.ex. Mindtalk")
    @State private var exampleHeard = String(localized: "t.ex. mind talk, mintalk")
    @State private var imported: Int?

    private enum Sort: String, CaseIterable {
        case newest, alphabetical, used
        var title: LocalizedStringKey {
            switch self {
            case .newest: return "Senast tillagda"
            case .alphabetical: return "A till Ö"
            case .used: return "Mest använda"
            }
        }
    }

    private var canAdd: Bool { Vocabulary.isValidWord(Vocabulary.tidy(word)) && problem == nil }

    /// Why "Lägg till" can't be pressed — said under the fields.
    private var problem: String? {
        let word = Vocabulary.tidy(word)
        if word.count > 60 { return String(localized: "Ordet är för långt. Högst 60 tecken.") }
        if !word.isEmpty, !Vocabulary.isValidWord(word) { return String(localized: "Skriv ett ord med bokstäver eller siffror.") }
        let variants = heardAs.split(separator: ",").map { Vocabulary.tidy(String($0)) }.filter { !$0.isEmpty }
        if variants.contains(where: { $0.count > 60 }) { return String(localized: "Det som brukar bli fel är för långt. Högst 60 tecken.") }
        if !word.isEmpty, variants.contains(where: { Vocabulary.key($0) == Vocabulary.key(word) }) {
            return String(localized: "Skriv hur det brukar bli fel, inte samma ord en gång till.")
        }
        // Another word on the list as a variant would rewrite that word everywhere.
        if let taken = variants.first(where: { Vocabulary.isOtherWord($0, than: word, in: vocabulary.entries) }) {
            return String(localized: "”\(taken)” finns redan som eget ord.")
        }
        return nil
    }

    private var shown: [VocabularyEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let sorted: [VocabularyEntry] = {
            switch Sort(rawValue: sort) ?? .newest {
            case .newest: return vocabulary.entries
            case .alphabetical: return vocabulary.entries.sorted { $0.word.localizedStandardCompare($1.word) == .orderedAscending }
            case .used: return vocabulary.entries.sorted { $0.fixes > $1.fixes }
            }
        }()
        guard !q.isEmpty else { return sorted }
        return sorted.filter { e in
            e.word.localizedCaseInsensitiveContains(q) || e.heardAs.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Ordlista", eyebrow: eyebrow)
                .padding(.bottom, 4)
                .staggered(0)
            tile.staggered(0)
            ListenerOffer().staggered(0)
            if !vocabulary.suggestions.isEmpty { suggestionsCard.staggered(0) }

            SectionTitle("Lägg till")
            .staggered(0)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) {
                    field("Ord", placeholder: example, text: $word)
                        .focused($wordFocused)
                    field("Hörs ofta som (valfritt)", placeholder: exampleHeard, text: $heardAs)
                    Button("Lägg till", action: add)
                        .buttonStyle(.ink)
                        .disabled(!canAdd)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.Colors.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: problem)
            .padding(20)
            .card()
            .staggered(0)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionTitle(vocabulary.entries.isEmpty ? String(localized: "Dina ord") : String(localized: "Dina ord · \(vocabulary.entries.count)"))
                Spacer()
                if vocabulary.entries.count > 8 {
                    TextField("Sök i ordlistan", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                if vocabulary.entries.count > 1 {
                    MenuPicker(options: Sort.allCases.map { ($0.rawValue, String(localized: String.LocalizationValue($0.rawValue == "newest" ? "Senast tillagda" : $0.rawValue == "alphabetical" ? "A till Ö" : "Mest använda"))) },
                               selection: $sort)
                        .fixedSize()
                }
                Menu {
                    Button("Importera…", action: importList)
                    Button("Exportera…", action: exportList).disabled(vocabulary.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(DS.Colors.muted)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Importera eller exportera ordlistan")
                .accessibilityLabel("Mer")
            }
            if let imported {
                Text(imported == 1 ? "1 ord lades till." : "\(imported) ord lades till.")
                    .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
            VStack(spacing: 0) {
                if vocabulary.entries.isEmpty {
                    Text("Inga ord än. Lägg till namn och ord du ofta säger.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                } else if shown.isEmpty {
                    Text("Inga ord matchar ”\(search)”.")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, entry in
                    if i > 0 { CardDivider() }
                    VocabularyRow(entry: entry, vocabulary: vocabulary, highlighted: highlighted == entry.id)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .card()
            .animation(.spring(duration: 0.4, bounce: 0.15), value: vocabulary.entries.map(\.id))

            SectionTitle("Prova ordlistan")
            .staggered(1)
            VStack(alignment: .leading, spacing: 12) {
                TextField("Skriv en mening som Mindtalk kan ha hört, t.ex. ”jag använder mind talk”", text: $sample)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                if !sample.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(DS.Colors.muted)
                        Text(preview).font(.system(size: 14))
                    }
                }
            }
            .padding(20)
            .card()
            .staggered(1)

            if !vocabulary.entries.isEmpty {
                ListenerRow(status: .shared)
                    .staggered(1)
            }

            Text("Varianter rättas alltid, så lägg bara till sådant du aldrig menar på riktigt. Skriv flera med komma emellan. Korta vanliga ord (som ”per” eller ”test”), text i versaler och e-post- och webbadresser lämnas orörda. Det går också att ersätta förkortningar: lägg ”btw” som variant till ”förresten”.")
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .modifier(PageScroll(on: !plain))
        .onAppear {
            VocabularyBoostStatus.shared.refresh()      // deleted in Finder, or put back
            takePendingHeard()
        }
        // Already on screen when "Lägg till i Ordlista…" was chosen.
        .onReceive(NotificationCenter.default.publisher(for: .addToVocabulary)) { _ in takePendingHeard() }
        .overlay(alignment: .bottom) {
            if let toast = vocabulary.toast {
                HStack(spacing: 12) {
                    Text(verbatim: toast).font(.system(size: 13, weight: .medium))
                    Button("Ångra") { withAnimation(.snappy) { vocabulary.undoLast() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .keyboardShortcut("z", modifiers: .command)
                }
                .foregroundStyle(DS.Colors.onInk)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Capsule().fill(DS.Colors.ink))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .id(toast)
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.12), value: vocabulary.toast)
    }

    /// Over the title: how many words, and how often they've been put right.
    private var eyebrow: String? {
        let own = vocabulary.entries
        guard !own.isEmpty else { return nil }
        let fixes = own.reduce(0) { $0 + $1.fixes }
        var parts = [own.count == 1 ? String(localized: "1 ord") : String(localized: "\(own.count) ord")]
        if fixes > 0 {
            parts.append(fixes == 1 ? String(localized: "rättat 1 gång") : String(localized: "rättat \(Stats.number(fixes)) gånger"))
        }
        return parts.joined(separator: " · ")
    }

    /// What the list is and what it has done — on the light tile, like Hem.
    private var tile: some View {
        let own = vocabulary.entries
        let top = own.max { $0.fixes < $1.fixes }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Namn och ord som Mindtalk ska stava som du vill i diktering, tankar och möten. Isärskrivna eller felhörda varianter, som ”Mind Talk”, rättas av sig själva.")
                .font(.system(size: 14, weight: .regular, design: .serif)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
            if !vocabulary.hasOwnWords {
                // No words of your own yet: what's worth adding, each with how it's heard.
                HStack(spacing: 8) {
                    exampleChip("Namn på kollegor", String(localized: "t.ex. en kollegas namn"), String(localized: "t.ex. som namnet brukar höras"))
                    exampleChip("Företag och produkter", String(localized: "t.ex. Mindact"), String(localized: "t.ex. mind act, min dakt"))
                    exampleChip("Förkortningar", String(localized: "t.ex. förresten"), String(localized: "t.ex. btw"))
                }
            } else if let top, top.fixes > 0 {
                Text(verbatim: String(localized: "Mest använt: \(top.word)")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile()
    }

    /// Something worth adding, as a soft chip: a press puts the example in both fields.
    private func exampleChip(_ title: LocalizedStringKey, _ hint: String, _ heardHint: String) -> some View {
        Button {
            example = hint
            exampleHeard = heardHint
            wordFocused = true
        } label: {
            Text(title).font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(DS.Colors.control).shadow(color: .black.opacity(0.06), radius: 2, y: 1))
                .overlay(Capsule().strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Words worth adding — a yes or a no each.
    private var suggestionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(vocabulary.suggestions.prefix(5).enumerated()), id: \.element.id) { i, suggestion in
                if i > 0 { CardDivider() }
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(DS.Colors.muted).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lägg till ”\(suggestion.word)”?").font(.system(size: 14, weight: .semibold))
                        Text(verbatim: [suggestion.heardAs.first.map { String(localized: "hördes som ”\($0)”") },
                                        suggestion.source.map { String(localized: "från mötet \($0)") }]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Button("Inte nu") { withAnimation(.snappy) { vocabulary.decline(suggestion) } }.buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Colors.muted)
                    Button("Lägg till") { withAnimation(.snappy) { vocabulary.accept(suggestion) } }.buttonStyle(.soft)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .card()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        withAnimation(.snappy) { imported = vocabulary.importText(text) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { imported = nil }
    }

    private func exportList() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Ordlista") + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vocabulary.exportText().write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { NSSound.beep() }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label)).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Colors.muted)
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
                .onSubmit(add)
        }
    }

    /// How a word was heard, from Diktering: in "Hörs ofta som", the cursor in "Ord".
    private func takePendingHeard() {
        guard let heard = Self.pendingHeard else { return }
        Self.pendingHeard = nil
        word = ""
        heardAs = heard
        search = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { wordFocused = true }
    }

    private func add() {
        guard canAdd else { return }
        var id: UUID?
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) { id = vocabulary.add(word: word, heardAs: heardAs) }
        word = ""
        heardAs = ""
        search = ""
        wordFocused = true
        // Show where it went — also when it was merged into an existing word.
        highlighted = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if highlighted == id { highlighted = nil } }
    }

    /// The sample with every fixed word in bold.
    private var preview: AttributedString {
        let result = vocabulary.preview(sample)
        var attributed = AttributedString(result.text)
        for range in result.ranges {
            guard let r = Range(range, in: result.text),
                  let lower = AttributedString.Index(r.lowerBound, within: attributed),
                  let upper = AttributedString.Index(r.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = DS.Colors.accent
            attributed[lower..<upper].font = .system(size: 14, weight: .semibold)
        }
        return attributed
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    @ObservedObject var vocabulary: Vocabulary
    let highlighted: Bool
    @Environment(\.undoManager) private var undo
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var addingVariant = false
    @State private var newVariant = ""
    @FocusState private var focus: Field?

    private enum Field { case word, variant }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if editing {
                    TextField("Ord", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: 260)
                        .focused($focus, equals: .word)
                        .onSubmit(commitRename)
                        .onExitCommand { editing = false }
                } else {
                    HStack(spacing: 8) {
                        Text(entry.word)
                            .font(.system(size: 15, weight: .semibold))
                            .onTapGesture(count: 2) { startRename() }
                            .help("Dubbelklicka för att ändra")
                        if let source = entry.source {
                            Label("Från möte", systemImage: "sparkles").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(DS.Colors.muted)
                                .help(String(localized: "Föreslogs från mötet \(source)"))
                        }
                    }
                }
                FlowLayout(spacing: 6) {
                    if !entry.heardAs.isEmpty {
                        Text("hörs ofta som").font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                    }
                    ForEach(entry.heardAs, id: \.self) { variant in
                        VariantChip(text: variant) {
                            withAnimation(.snappy) { vocabulary.removeVariant(variant, from: entry, undo: undo) }
                        }
                    }
                    if addingVariant {
                        TextField("hörs som", text: $newVariant)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 150)
                            .focused($focus, equals: .variant)
                            .onSubmit(commitVariant)
                            .onExitCommand { addingVariant = false }
                    } else {
                        Button {
                            newVariant = ""
                            addingVariant = true
                            focus = .variant
                        } label: {
                            Label("Hörs som", systemImage: "plus").font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.Colors.muted)
                        .opacity(hovering || entry.heardAs.isEmpty ? 1 : 0.6)
                        .help("Lägg till något Mindtalk brukar höra fel")
                    }
                }
            }
            Spacer(minLength: 12)
            Text(entry.fixes == 0 ? String(localized: "Inte använt än")
                 : entry.fixes == 1 ? String(localized: "Rättat 1 gång") : String(localized: "Rättat \(entry.fixes) gånger"))
                .font(.system(size: 12))
                .foregroundStyle(DS.Colors.muted)
            Button(action: startRename) {
                Image(systemName: "pencil").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.muted)
            .opacity(hovering ? 1 : 0.35)
            .help("Ändra \(entry.word)")
            .accessibilityLabel("Ändra \(entry.word)")
            Button {
                withAnimation(.snappy) { vocabulary.remove(entry, undo: undo) }
            } label: {
                Image(systemName: "trash").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.Colors.muted)
            .opacity(hovering ? 1 : 0.7)
            .help("Ta bort \(entry.word)")
            .accessibilityLabel("Ta bort \(entry.word)")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(DS.Colors.chip.opacity(highlighted ? 0.8 : 0).animation(.easeOut(duration: 0.6), value: highlighted))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: focus) { _, now in
            // Clicking elsewhere ends editing.
            if now != .word, editing { commitRename() }
            if now != .variant, addingVariant { commitVariant() }
        }
    }

    private func startRename() {
        draft = entry.word
        editing = true
        focus = .word
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        if draft != entry.word { withAnimation(.snappy) { vocabulary.rename(entry, to: draft) } }
    }

    private func commitVariant() {
        guard addingVariant else { return }
        addingVariant = false
        // One that can't be added (another word on the list, say) is left out, with a beep.
        var refused = false
        for v in newVariant.split(separator: ",") where !vocabulary.addVariant(String(v), to: entry) { refused = true }
        if refused { NSSound.beep() }
    }
}

private struct VariantChip: View {
    let text: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(DS.Colors.muted))
            .help("Ta bort ”\(text)” (⌘Z ångrar)")
            .accessibilityLabel("Ta bort \(text)")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(DS.Colors.chip))
        .onHover { hovering = $0 }
    }
}

/// Lays its children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.items.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current.items.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

/// The listener that makes the speech model hear your words — and where it stands.
private struct ListenerRow: View {
    @ObservedObject var status: VocabularyBoostStatus
    @ObservedObject var vocabulary = Vocabulary.shared
    /// The offer above (ListenerOffer) has been answered: only then is "Ladda ned"
    /// here too, so the page never asks twice.
    @AppStorage("listenerOfferAnswered") private var offerAnswered = false
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(status.state == .ready ? DS.Colors.good : DS.Colors.muted)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if case .failed = status.state {
                if VocabularyBoost.isInstalled {
                    Button("Ladda ned igen") { vocabulary.refetchListener() }.buttonStyle(.soft)
                } else {
                    Button("Försök igen") { vocabulary.fetchListener() }.buttonStyle(.soft)
                }
            } else if status.state == .missing, vocabulary.hasOwnWords, offerAnswered || Settings.listenerAllowed {
                Button("Ladda ned \(VocabularyBoost.sizeText)") { vocabulary.allowListener() }.buttonStyle(.soft)
            } else if status.state == .ready {
                // The only place the listener is: Finder and removal too.
                Menu {
                    Button("Visa i Finder") { DiskSize.reveal(VocabularyBoost.directory) }
                    Divider()
                    Button("Ta bort…", role: .destructive) { confirmRemove = true }
                } label: { ModelParts.more }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Mer")
                .accessibilityLabel(Text("Mer om lyssnaren"))
            }
        }
        .padding(18)
        .card()
        .confirmationDialog("Ta bort lyssnaren?", isPresented: $confirmRemove) {
            Button("Ta bort", role: .destructive) { vocabulary.removeListener() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Dina ord rättas ändå i texten. Den kan laddas ned igen senare.")
        }
    }

    private var symbol: String {
        switch status.state {
        case .ready: "ear.fill"
        case .downloading: "arrow.down.circle"
        case .missing: "ear"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var title: LocalizedStringKey {
        switch status.state {
        case .ready: "Talmodellen hör dina ord"
        case .downloading: "Lyssnaren laddas ned"
        case .missing: "Låt talmodellen höra dina ord"
        case .failed: "Lyssnaren kunde inte laddas"
        }
    }

    private var detail: String {
        switch status.state {
        case .ready:
            return String(localized: "När något du dikterar liknar ett ord i listan lyssnar Mindtalk en gång till just där, så att namnet stavas rätt.")
                + " " + String(localized: "Lyssnaren (Parakeet CTC), \(VocabularyBoost.sizeText).")
        case .downloading:
            return String(localized: "Laddar ned lyssnaren (\(VocabularyBoost.sizeText)). Det sker bara en gång, sedan fungerar den utan internet.")
        case .missing:
            return vocabulary.hasOwnWords
                ? String(localized: "Med en liten lyssnare (\(VocabularyBoost.sizeText)) stavas namnen rätt redan när du pratar. Den laddas ned en gång och fungerar sedan utan internet. Utan den rättas dina ord ändå i texten.")
                : String(localized: "Lägger du till ett eget ord kan du ladda ned en liten lyssnare (\(VocabularyBoost.sizeText)), så att namn stavas rätt redan när du pratar.")
        case .failed(let why):
            return why + " " + String(localized: "Dina ord rättas ändå i texten som vanligt.")
        }
    }
}

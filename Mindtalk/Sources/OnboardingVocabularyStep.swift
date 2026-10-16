import SwiftUI

// MARK: - Step 7: The word list
//
// Shown rather than told: a sentence as the speech model heard it, and the one
// word the list spells right — on the night tile, like the Ordlista page. Then
// your own first word, which drops into a small copy of the list as it looks in
// the app. One bouncy spring, for the moment of correction. Each example plays
// once, then the corrected sentence stays; it skips to that as soon as you start
// typing a word of your own, and with Reduce Motion it just stands there. The
// demo never touches your list — only "Lägg till" does.

struct VocabularyStep: View {
    let dictation: Dictation
    @Binding var done: Bool
    @ObservedObject private var vocabulary = Vocabulary.shared
    /// The word just added (or merged into) — lit up in the list for a moment.
    @State private var highlighted: UUID?
    /// Added in this step: the card says so, instead of asking again.
    @State private var added: AddResult?
    /// In one of the fields: the demo above stops moving.
    @State private var typing = false

    /// A word typed but not yet added — "Öppna Mindtalk" adds it rather than lose it.
    /// Set while the card holds a word that can be added; nil otherwise.
    @MainActor static var commitPending: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(title: "Lär Mindtalk dina ord",
                       subtitle: "Namn och ord på listan stavas rätt i allt du dikterar – också i tankar och möten.")
                .staggered(0)
            VStack(spacing: DS.Layout.stepGap) {
                CorrectionDemo(stopped: typing)
                    .staggered(1)
                HStack(alignment: .top, spacing: DS.Layout.stepGap) {
                    FirstWordCard(vocabulary: vocabulary, hasOwnWords: hasOwnWords,
                                  added: $added, highlighted: $highlighted, done: $done, typing: $typing)
                        .frame(height: 186)
                    // As tall as what's on it, no taller.
                    MiniWordList(entries: entries, highlighted: highlighted, showsSlot: added == nil)
                }
                .staggered(2)
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Text("Namn du ger talarna i ett möte föreslås till listan. Hela listan finns under Ordlista.")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .padding(.top, 4)
                .staggered(3)
            }
        }
        #if DEBUG
        .onAppear { if VocabularyStepRender.added { added = .added("Kubernetes"); done = true } }
        #endif
    }

    private var entries: [VocabularyEntry] {
        #if DEBUG
        if VocabularyStepRender.on { return VocabularyStepRender.entries }
        #endif
        return vocabulary.entries
    }

    private var hasOwnWords: Bool {
        #if DEBUG
        if VocabularyStepRender.on { return VocabularyStepRender.added }
        #endif
        return vocabulary.hasOwnWords
    }
}

/// What "Lägg till" did: a new word, or one that was already on the list.
private enum AddResult: Equatable {
    case added(String)
    /// Already there — with the "hörs som" variants that were new, if any.
    case existing(String, newVariants: [String])
}

#if DEBUG
/// `--render-onboarding … --onboarding-step vocabulary [--vocabulary-added]`: the
/// finished demo and made-up words, so the picture never shows (or writes) your list.
private enum VocabularyStepRender {
    static let on = CommandLine.arguments.contains("--render-onboarding")
    static let added = on && CommandLine.arguments.contains("--vocabulary-added")
    static var entries: [VocabularyEntry] {
        (added ? [VocabularyEntry(word: "Kubernetes", heardAs: ["kuber netes"])] : [])
            + [VocabularyEntry(word: "Mindtalk")]
    }
}
#endif

// MARK: - Before and after

/// A sentence types itself as the speech model heard it; the misheard word is
/// struck out and springs into the spelling from your list. Two examples, each
/// played once — then it rests on the corrected sentence. Stopped (you're typing
/// below): straight to the corrected sentence, and still.
private struct CorrectionDemo: View {
    let stopped: Bool

    private struct Example {
        let before: String
        let heard: String
        let fixed: String
        let after: String
        var count: Int { before.count + 1 + heard.count + 1 + after.count }
    }

    private static let examples = [
        Example(before: String(localized: "Vi hörs på"), heard: String(localized: "tims"),
                fixed: String(localized: "Teams"), after: String(localized: "i morgon.")),
        Example(before: String(localized: "Jag dikterar allt med"), heard: String(localized: "mind talk"),
                fixed: String(localized: "Mindtalk"), after: String(localized: "nu.")),
    ]

    private enum Stage { case typing, marked, fixed }

    @State private var index = 0
    @State private var typed = 0
    @State private var stage = Stage.typing
    @State private var lineShown = true
    /// Played through, or stopped: it stays on the corrected sentence from now on.
    @State private var ended = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var example: Example { Self.examples[index] }
    private static let font = Font.system(size: 28, weight: .regular, design: .serif)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: stage == .fixed ? "checkmark" : "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
                Text(stage == .fixed ? "Så skrivs det" : "Så hördes det")
                    .contentTransition(.opacity)
                Spacer()
                HStack(spacing: 5) {
                    ForEach(Self.examples.indices, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(i == index ? 0.75 : 0.22))
                            .frame(width: i == index ? 14 : 5, height: 5)
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 22)
            .padding(.top, 18)

            Spacer(minLength: 0)
            sentence
                .opacity(lineShown ? 1 : 0)
                .blur(radius: lineShown ? 0 : 4)
                // Room below the line for the chip under the word.
                .padding(.bottom, 30)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 158)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).fill(DS.Colors.night)
                .overlay(
                    // A faint light from above, where the words land.
                    RadialGradient(colors: [.white.opacity(0.07), .clear], center: .top, startRadius: 0, endRadius: 320)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Exempel: Mindtalk hörde ”\(example.heard)” och skrev ”\(example.fixed)” – från din ordlista."))
        // A new id cancels the play: stopping it is the same as having watched it.
        .task(id: stopped || ended) {
            if stopped || ended { settle() } else { await play() }
        }
    }

    // MARK: The line

    private var sentence: some View {
        let e = example
        let before = String(e.before.prefix(min(typed, e.before.count)))
        let heard = String(e.heard.prefix(max(0, typed - e.before.count - 1)))
        let after = String(e.after.prefix(max(0, typed - e.before.count - 1 - e.heard.count - 1)))
        return HStack(spacing: 0) {
            Text(verbatim: before)
            if !heard.isEmpty { word(heard: heard) }
            Text(verbatim: after)
            if stage == .typing { cursor }
        }
        .font(Self.font)
        .lineLimit(1)
        .fixedSize()
    }

    /// The misheard word, struck out, then the right one — highlighted, with where it came from.
    private func word(heard: String) -> some View {
        ZStack {
            if stage == .fixed {
                Text(verbatim: example.fixed)
                    .transition(.asymmetric(insertion: .modifier(active: Morph(t: 1, rise: 10), identity: Morph(t: 0, rise: 10)),
                                            removal: .opacity))
            } else {
                Text(verbatim: heard)
                    .strikethrough(stage == .marked, color: .white.opacity(0.8))
                    .foregroundStyle(.white.opacity(stage == .marked ? 0.45 : 1))
                    .transition(.modifier(active: Morph(t: 1, rise: -12), identity: Morph(t: 0, rise: -12)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(stage == .fixed ? 0.13 : 0))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(stage == .fixed ? 0.28 : 0), lineWidth: 1))
                .shadow(color: .white.opacity(stage == .fixed ? 0.22 : 0), radius: 14))
        .overlay(alignment: .bottom) {
            if stage == .fixed {
                FromListChip()
                    .fixedSize()
                    .offset(y: 32)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        // A space's width either side, outside the highlight.
        .padding(.horizontal, 5)
    }

    private var cursor: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let typing = typed > 0 && typed < example.count
            let on = typing || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            RoundedRectangle(cornerRadius: 1.25)
                .fill(.white.opacity(0.85))
                .frame(width: 2.5, height: 28)
                .padding(.leading, 2)
                .opacity(on ? 1 : 0)
        }
    }

    // MARK: The play

    private func play() async {
        #if DEBUG
        if VocabularyStepRender.on { showFinished(); return }
        #endif
        if reduceMotion { showFinished(); return }
        // Wait for the step's entrance before typing.
        guard await pause(0.9) else { return }
        for i in Self.examples.indices {
            index = i
            typed = 0
            stage = .typing
            withAnimation(.smooth(duration: 0.3)) { lineShown = true }
            guard await pause(0.35) else { return }
            let chars = Array(Self.examples[i].before + " " + Self.examples[i].heard + " " + Self.examples[i].after)
            for c in chars.indices {
                typed = c + 1
                guard await pause(chars[c] == " " ? 0.09 : Double.random(in: 0.04...0.075)) else { return }
            }
            guard await pause(0.55) else { return }
            withAnimation(.smooth(duration: 0.3)) { stage = .marked }
            guard await pause(0.75) else { return }
            // The moment it's fixed: the step's one bouncy spring.
            withAnimation(.spring(duration: 0.55, bounce: 0.38)) { stage = .fixed }
            // The last one stays.
            guard i < Self.examples.count - 1 else { break }
            guard await pause(3.2) else { return }
            withAnimation(.smooth(duration: 0.45)) { lineShown = false }
            guard await pause(0.5) else { return }
        }
        ended = true
    }

    /// Stopped midway: the example on screen, corrected — no spring, nothing more to come.
    private func settle() {
        guard !(stage == .fixed && lineShown && typed == example.count) else { return }
        withAnimation(.smooth(duration: 0.3)) {
            typed = example.count
            stage = .fixed
            lineShown = true
        }
    }

    private func showFinished() {
        index = 0
        typed = Self.examples[0].count
        stage = .fixed
        lineShown = true
    }

    /// False when the step has gone — the loop ends with it.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// A word comes into focus from a blur and a little offset.
private struct Morph: ViewModifier {
    let t: Double
    let rise: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(1 - t)
            .blur(radius: 6 * t)
            .scaleEffect(1 - 0.25 * t)
            .offset(y: rise * t)
    }
}

/// "Från din ordlista", under the corrected word — like the chips on the Ordlista tile.
private struct FromListChip: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.book.closed.fill").font(.system(size: 10))
            Text("Från din ordlista")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Your first word

private struct FirstWordCard: View {
    @ObservedObject var vocabulary: Vocabulary
    /// The listener (100 MB), offered the moment there's a word for it to hear.
    @ObservedObject private var listener = VocabularyBoostStatus.shared
    let hasOwnWords: Bool
    @Binding var added: AddResult?
    @Binding var highlighted: UUID?
    @Binding var done: Bool
    /// In either field — the demo above holds still meanwhile.
    @Binding var typing: Bool
    @State private var word = ""
    @State private var heardAs = ""
    @FocusState private var wordFocused: Bool
    @FocusState private var heardAsFocused: Bool
    @State private var shownAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canAdd: Bool { Vocabulary.isValidWord(Vocabulary.tidy(word)) && problem == nil }

    /// Why "Lägg till" can't be pressed — shown in place of the line under the title.
    private var problem: String? {
        let word = Vocabulary.tidy(word)
        if word.count > 60 { return String(localized: "Ordet är för långt – högst 60 tecken.") }
        if !word.isEmpty, !Vocabulary.isValidWord(word) { return String(localized: "Skriv ett ord med bokstäver eller siffror.") }
        let variants = heardAs.split(separator: ",").map { Vocabulary.tidy(String($0)) }.filter { !$0.isEmpty }
        if variants.contains(where: { $0.count > 60 }) { return String(localized: "Det som brukar bli fel är för långt – högst 60 tecken.") }
        if !word.isEmpty, variants.contains(where: { Self.key($0) == Self.key(word) }) {
            return String(localized: "Skriv hur det brukar bli fel – inte samma ord en gång till.")
        }
        return nil
    }

    /// As the list compares words: "Mind Talk" and "mindtalk" are the same.
    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let added {
                confirmation(added)
                    .transition(swap)
            } else {
                form
                    .transition(swap)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .raised(cornerRadius: DS.Radius.panel)
        // "Öppna Mindtalk" adds what you typed rather than lose it.
        .onChange(of: [word, heardAs]) { registerPending() }
        // You click into a field, or start typing: the demo stops. Not for a focus that
        // comes by itself as the step appears — macOS may hand the first field focus.
        .onChange(of: wordFocused || heardAsFocused) { _, now in
            if now, let shownAt, Date().timeIntervalSince(shownAt) > 0.5 { typing = true }
        }
        .onChange(of: word.isEmpty && heardAs.isEmpty) { _, empty in if !empty { typing = true } }
        .onAppear { shownAt = Date() }
        .onDisappear { VocabularyStep.commitPending = nil }
    }

    private func registerPending() {
        guard canAdd else { VocabularyStep.commitPending = nil; return }
        let (word, heardAs) = (word, heardAs)
        VocabularyStep.commitPending = { Vocabulary.shared.add(word: word, heardAs: heardAs) }
    }

    private var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .modifier(active: Morph(t: 0.4, rise: 6), identity: Morph(t: 0, rise: 6)))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hasOwnWords ? "Lägg till ett ord" : "Lägg till ditt första ord")
                .font(.system(size: 15, weight: .semibold))
            Group {
                if let problem {
                    Label(problem, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(DS.Colors.warning)
                } else {
                    Text("Ett företag, en produkt eller ett ord från jobbet.")
                        .foregroundStyle(DS.Colors.muted)
                }
            }
            .font(.system(size: 12.5))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
            .animation(.smooth(duration: 0.25), value: problem)
            Spacer(minLength: 10)
            field(String(localized: "t.ex. ett företagsnamn"), text: $word)
                .focused($wordFocused)
            HStack(spacing: 8) {
                // Its own words here; the Ordlista page keeps "Hörs ofta som".
                field(String(localized: "Blir ofta fel som (valfritt)"), text: $heardAs)
                    .focused($heardAsFocused)
                Button("Lägg till", action: add)
                    .buttonStyle(.ink)
                    .disabled(!canAdd)
                    .animation(.snappy(duration: 0.2), value: canAdd)
            }
            .padding(.top, 8)
        }
    }

    private func confirmation(_ result: AddResult) -> some View {
        let new = isNew(result)
        return VStack(alignment: .leading, spacing: 0) {
            Image(systemName: new ? "checkmark" : "text.book.closed.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(new ? DS.Colors.onInk : DS.Colors.accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(new ? AnyShapeStyle(DS.Colors.ink) : AnyShapeStyle(DS.Colors.chip)))
                .shadow(color: .black.opacity(new ? 0.18 : 0), radius: 10, y: 4)
            Group {
                switch result {
                case .added: Text("Tillagt!")
                case .existing(_, let variants): Text(variants.isEmpty ? "Finns redan" : "Fanns redan")
                }
            }
            .font(.system(size: 17, weight: .semibold))
            .padding(.top, 14)
            Group {
                switch result {
                case .added(let word) where listener.state == .downloading:
                    Text("Laddar ned lyssnaren – sedan blir ”\(word)” rätt redan när du pratar.")
                case .added(let word) where offersListener:
                    Text("Ladda ned lyssnaren (\(VocabularyBoost.sizeText)), så blir ”\(word)” rätt redan när du pratar.")
                case .added(let word):
                    Text("Från och med nu stavas ”\(word)” så i allt du dikterar.")
                case .existing(let word, let variants) where variants.isEmpty:
                    Text("”\(word)” finns redan i din ordlista.")
                case .existing(let word, let variants):
                    // "”mind talk” och ”mintalk”" — the "och" in the app's language.
                    Text("Nu rättas också \(variants.map { "”\($0)”" }.formatted(.list(type: .and))) till ”\(word)”.")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(DS.Colors.muted)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                if case .added = result, offersListener {
                    Button("Ladda ned \(VocabularyBoost.sizeText)") { Vocabulary.shared.allowListener() }
                        .buttonStyle(.ink)
                        .help("Lyssnaren hör dina ord direkt – också namn som låter som vanliga ord")
                }
                Button("Lägg till fler") {
                    withAnimation(.smooth(duration: 0.35)) { added = nil }
                    DispatchQueue.main.async { wordFocused = true }
                }
                .buttonStyle(SoftButtonStyle(small: true))
            }
        }
    }

    /// No listener yet, and not asked for: the moment to offer it.
    private var offersListener: Bool {
        listener.state == .missing && !Settings.listenerAllowed
    }

    private func isNew(_ result: AddResult) -> Bool {
        if case .added = result { return true }
        return false
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Colors.field))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
            .onSubmit(add)
    }

    private func add() {
        guard canAdd else {
            if !word.isEmpty || problem != nil { NSSound.beep() }
            return
        }
        let first = !done
        // What was there before tells a new word from one already on the list.
        let before = Dictionary(vocabulary.entries.map { ($0.id, $0.heardAs) }, uniquingKeysWith: { a, _ in a })
        var result: AddResult?
        var id: UUID?
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.5)) {
            id = vocabulary.add(word: word, heardAs: heardAs)
            guard let id, let entry = vocabulary.entries.first(where: { $0.id == id }) else { return }
            if let old = before[id] {
                result = .existing(entry.word, newVariants: entry.heardAs.filter { !old.contains($0) })
            } else {
                result = .added(entry.word)
            }
            added = result
            highlighted = id
        }
        guard let id, let result else { NSSound.beep(); return }
        word = ""
        heardAs = ""
        wordFocused = false
        VocabularyStep.commitPending = nil
        done = true
        if first, isNew(result) { Cue.celebrate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if highlighted == id { withAnimation(.smooth(duration: 0.6)) { highlighted = nil } }
        }
    }
}

// MARK: - The list, as in the app

/// The top of your word list, as it looks under Ordlista — the new word drops in at the top.
private struct MiniWordList: View {
    let entries: [VocabularyEntry]
    let highlighted: UUID?
    /// Until you've added a word here: where it will land.
    let showsSlot: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The newest few — and the one just added, if it was further down.
    private var rows: [VocabularyEntry] {
        let room = showsSlot ? 2 : 3
        var rows = Array(entries.prefix(room))
        if let id = highlighted, !rows.contains(where: { $0.id == id }), let e = entries.first(where: { $0.id == id }) {
            rows = [e] + rows.prefix(room - 1)
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dina ord").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(verbatim: "\(entries.count)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Colors.muted)
                    .contentTransition(.numericText(value: Double(entries.count)))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if showsSlot {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                    Text("Ditt ord hamnar här")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.Colors.muted)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Colors.fieldStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .transition(.opacity)
            } else if entries.isEmpty {
                Text("Inga ord än.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, entry in
                VStack(spacing: 0) {
                    if i > 0 { Rectangle().fill(DS.Colors.divider).frame(height: 1).padding(.horizontal, 18) }
                    MiniWordRow(entry: entry, highlighted: highlighted == entry.id)
                }
                .transition(reduceMotion ? .opacity
                            : .asymmetric(insertion: .modifier(active: DropIn(t: 1), identity: DropIn(t: 0)), removal: .opacity))
            }
            if entries.count > rows.count {
                Text("och \(entries.count - rows.count) till")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
        .padding(.bottom, 4)
        .frame(width: 286, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .raised(cornerRadius: DS.Radius.panel)
        .accessibilityElement(children: .combine)
    }
}

/// Drops in from above, coming into focus.
private struct DropIn: ViewModifier {
    let t: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - t)
            .blur(radius: 5 * t)
            .scaleEffect(1 - 0.06 * t, anchor: .top)
            .offset(y: -22 * t)
    }
}

private struct MiniWordRow: View {
    let entry: VocabularyEntry
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: entry.word)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if entry.source != nil {
                        Label("Från möte", systemImage: "sparkles")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(DS.Colors.muted)
                    }
                }
                if let variant = entry.heardAs.first {
                    HStack(spacing: 5) {
                        Text("hörs som").foregroundStyle(DS.Colors.muted)
                        Text(verbatim: variant)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(DS.Colors.chip))
                        if entry.heardAs.count > 1 {
                            Text(verbatim: "+\(entry.heardAs.count - 1)").foregroundStyle(DS.Colors.muted)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }
            Spacer(minLength: 8)
            Text(entry.fixes == 0 ? String(localized: "Inte använt än")
                 : entry.fixes == 1 ? String(localized: "Rättat 1 gång") : String(localized: "Rättat \(entry.fixes) gånger"))
                .font(.system(size: 11))
                .foregroundStyle(DS.Colors.muted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Colors.chip.opacity(highlighted ? 0.8 : 0))
    }
}

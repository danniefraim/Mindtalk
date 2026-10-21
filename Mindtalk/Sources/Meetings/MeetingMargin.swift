import SwiftUI

// MARK: - While a meeting records: the margin beside the text
//
// The conversation is the page. Your own things live in a narrow margin to its right,
// always in the same place: what you have noted and marked so far, the field to write
// in, and the three marks with their words and keys. A click on something in the list
// shows that moment in the text. In a narrow window the field and the marks stand in
// one row under the text instead, and your notes stand in the text where you wrote them.

/// The margin: your notes and marks so far, the field, the marks.
struct LiveMargin: View {
    @ObservedObject var session: MeetingSession
    let record: MeetingRecord
    /// A moment in the list clicked: show it in the text.
    let show: (Double) -> Void
    var remove: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dina anteckningar")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.Colors.muted)
                .accessibilityAddTraits(.isHeader)
            MarginList(record: record, show: show, remove: remove)
                .frame(maxHeight: .infinity, alignment: .top)
            MarginNoteField(session: session)
            MarkButtons(session: session, layout: .rows)
        }
        .padding(.top, DS.Layout.pageTop + 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .leading) { Rectangle().fill(DS.Colors.divider).frame(width: 0.5) }
    }
}

/// A narrow window: the field and the marks in one row under the text.
struct MarginRow: View {
    @ObservedObject var session: MeetingSession

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            MarginNoteField(session: session, oneLine: true)
            MarkButtons(session: session, layout: .row)
        }
    }
}

/// What you noted and marked so far, oldest first, the newest in view. Each line is
/// the moment in the text, a click away.
private struct MarginList: View {
    let record: MeetingRecord
    let show: (Double) -> Void
    var remove: ((UUID) -> Void)?
    @State private var hovered: String?

    private enum Item: Identifiable {
        case mark(MeetingRecord.Mark)
        case note(Int, MeetingRecord.Note)

        var id: String {
            switch self {
            case .mark(let m): return "m" + m.id.uuidString
            case .note(let i, _): return "n\(i)"
            }
        }

        var at: Double? {
            switch self {
            case .mark(let m): return m.at
            case .note(_, let n): return n.at
            }
        }
    }

    private var items: [Item] {
        let marks = record.marks.map(Item.mark)
        let notes = record.notes.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { Item.note($0.offset, $0.element) }
        // By moment; notes without one (written before the recording ran) last.
        return (marks + notes).enumerated().sorted { a, b in
            let x = a.element.at ?? .infinity, y = b.element.at ?? .infinity
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    var body: some View {
        let all = items
        if all.isEmpty {
            Text("Det du skriver och markerar hamnar här.")
                .font(.system(size: 12.5))
                .foregroundStyle(DS.Colors.faint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(all) { item in row(item).id(item.id) }
                    }
                    .padding(.horizontal, -8)
                }
                .scrollIndicators(.automatic)
                .onChange(of: all.count, initial: true) { _, _ in
                    guard let last = all.last?.id else { return }
                    DispatchQueue.main.async { withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        Button { if let at = item.at { show(at) } } label: {
            VStack(alignment: .leading, spacing: 2) {
                switch item {
                case .mark(let mark):
                    HStack(spacing: 5) {
                        Image(systemName: mark.kind.symbol).font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(mark.kind.title).font(.system(size: 12.5, weight: .semibold))
                        Text(verbatim: MeetingView.duration(mark.at))
                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DS.Colors.faint)
                    }
                    if let text = mark.text {
                        Text(verbatim: text).font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
                            .lineLimit(3)
                    }
                case .note(_, let note):
                    if let at = note.at {
                        Text(verbatim: MeetingView.duration(at))
                            .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DS.Colors.faint)
                    }
                    Text(verbatim: note.text).font(.system(size: 13)).lineLimit(4)
                }
            }
            .foregroundStyle(DS.Colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovered == item.id ? DS.Colors.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.at == nil ? Text(verbatim: "") : Text("Visa i texten"))
        .contextMenu {
            if case .mark(let mark) = item, let remove {
                Button("Ta bort markeringen") { withAnimation(.snappy) { remove(mark.id) } }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// The note you're writing, on paper: ↩ adds it with its moment, ⇧↩ gives a new line.
/// One draft with the panel's field (NoteDraft), so nothing is lost between them.
struct MarginNoteField: View {
    @ObservedObject var session: MeetingSession
    /// The narrow window's row: one line to begin with.
    var oneLine = false
    @ObservedObject private var draft = NoteDraft.shared
    @FocusState private var focused: Bool
    /// For a moment after ↩: a check in the field.
    @State private var added = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if draft.text.isEmpty {
                Group {
                    if oneLine {
                        Text("Skriv en anteckning och tryck ↩").lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Skriv en anteckning")
                            Text("Tryck ↩ för att spara").font(.system(size: 11.5))
                        }
                    }
                }
                .font(.system(size: 13.5))
                .foregroundStyle(DS.Colors.faint)
                .padding(.leading, 5)          // the text view's own line padding
                .allowsHitTesting(false)
            }
            editor
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: oneLine ? 34 : 58, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(focused ? DS.Colors.ink.opacity(0.5) : DS.Colors.fieldStroke, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if added {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.Colors.onInk)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(DS.Colors.ink))
                    .padding(6)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    @ViewBuilder private var editor: some View {
        #if DEBUG
        if NoteDraft.still {
            Text(verbatim: draft.text.isEmpty ? " " : draft.text)
                .font(.system(size: 13.5))
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .topLeading)
        } else {
            textEditor
        }
        #else
        textEditor
        #endif
    }

    private var textEditor: some View {
        TextEditor(text: $draft.text)
            .accessibilityLabel("Anteckning")
            .accessibilityHint("Tryck på retur så läggs anteckningen till. Skift och retur ger en ny rad.")
            .font(.system(size: 13.5))
            .foregroundStyle(DS.Colors.ink)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(minHeight: 18, maxHeight: oneLine ? 60 : 110)
            .fixedSize(horizontal: false, vertical: true)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                add()
                return .handled
            }
    }

    private func add() {
        guard session.record != nil, let taken = draft.take() else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.2)) { _ = session.addNote(taken.text, at: taken.at) }
        AccessibilityNotification.Announcement(String(localized: "Anteckningen är sparad")).post()
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { added = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) { added = false }
        }
    }
}

/// Beslut, Att göra and Viktigt with their words and keys (⌥⌘1, ⌥⌘2, ⌥⌘3). What you
/// wrote in the field goes with the mark as its words. Paused, there's nothing to mark.
struct MarkButtons: View {
    @ObservedObject var session: MeetingSession
    enum Arrangement { case rows, row }
    var layout: Arrangement = .rows
    @ObservedObject private var draft = NoteDraft.shared
    @State private var flashed: MeetingRecord.Mark.Kind?
    @State private var hovered: MeetingRecord.Mark.Kind?

    private var off: Bool { session.isPaused || !session.isRecording }

    var body: some View {
        let stack = layout == .rows ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        stack {
            ForEach(Array(MeetingRecord.Mark.Kind.allCases.enumerated()), id: \.element) { i, kind in
                button(kind, key: i + 1)
            }
        }
        .disabled(off)
        .opacity(session.isPaused ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: session.isPaused)
    }

    private func button(_ kind: MeetingRecord.Mark.Kind, key: Int) -> some View {
        Button { mark(kind) } label: {
            HStack(spacing: 7) {
                Image(systemName: flashed == kind ? "checkmark" : kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
                Text(flashed == kind ? String(localized: "Markerat") : kind.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize()
                if layout == .rows { Spacer(minLength: 6) }
                Text("⌥⌘\(key)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.Colors.faint)
                    .fixedSize()
            }
            .foregroundStyle(DS.Colors.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: layout == .rows ? .infinity : nil)
            .background(Capsule().fill(hovered == kind || flashed == kind ? DS.Colors.chip : DS.Colors.card))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? kind : (hovered == kind ? nil : hovered) }
        .keyboardShortcut(KeyEquivalent(Character("\(key)")), modifiers: [.command, .option])
        .help(Text(verbatim: kind.markHelp + "  ⌥⌘\(key)"))
        .accessibilityLabel(kind.markLabel)
        .accessibilityHint("Markerar det som sägs just nu (⌥⌘\(key)). Har du skrivit något följer det med.")
    }

    private func mark(_ kind: MeetingRecord.Mark.Kind) {
        guard session.isRecording else { return }
        // Something written: the mark's words, and the field is empty again.
        let taken = draft.take()
        withAnimation(.spring(duration: 0.35, bounce: 0.35)) { _ = session.mark(kind, text: taken?.text, at: taken?.at) }
        AccessibilityNotification.Announcement(String(localized: "Markerat: \(kind.title)")).post()
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) { flashed = kind }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if flashed == kind { withAnimation(.spring(duration: 0.4)) { flashed = nil } }
        }
    }
}

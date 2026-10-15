import AVFoundation
import AppKit
import CoreText
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Exporting a meeting
//
// "Exportera" on a meeting's page: the notes, the text, or both — as PDF, Word,
// Markdown or plain text — and the recording as .m4a, the text as subtitles (.srt).
// Everything is made here, on the Mac: the document is laid out once as blocks
// (title, a heading, a paragraph, a task…) and each format writes those blocks
// its own way, so a PDF and a Word file of the same meeting say the same thing.

enum MeetingExport {
    enum Content: CaseIterable {
        /// The notes, then the whole conversation — what you'd send round.
        case all, notes, text

        var title: LocalizedStringResource {
            switch self {
            case .all: return "Sammanfattning och text"
            case .notes: return "Bara sammanfattningen"
            case .text: return "Bara texten"
            }
        }

        /// After the meeting's name in the file's name.
        var suffix: String {
            switch self {
            case .all: return ""
            case .notes: return " – " + String(localized: "sammanfattning")
            case .text: return " – " + String(localized: "text")
            }
        }
    }

    enum Format: CaseIterable {
        case pdf, word, markdown, text

        var title: LocalizedStringResource {
            switch self {
            case .pdf: return "PDF"
            case .word: return "Word (.docx)"
            case .markdown: return "Markdown (.md)"
            case .text: return "Text (.txt)"
            }
        }

        var ext: String {
            switch self {
            case .pdf: return "pdf"
            case .word: return "docx"
            case .markdown: return "md"
            case .text: return "txt"
            }
        }
    }

    // MARK: Saving

    /// Asks where, then writes it. Said in an alert if it couldn't be.
    @MainActor static func save(_ record: MeetingRecord, _ content: Content, as format: Format) {
        guard let url = ask(name: fileName(record, content), ext: format.ext) else { return }
        do { try write(record, content, as: format, to: url) } catch { fail(error) }
    }

    @MainActor static func write(_ record: MeetingRecord, _ content: Content, as format: Format, to url: URL) throws {
        let blocks = blocks(record, content)
        do {
            switch format {
            case .pdf: try pdf(document(blocks)).write(to: url, options: .atomic)
            case .word:
                let doc = document(blocks)
                let data = try doc.data(from: NSRange(location: 0, length: doc.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                try data.write(to: url, options: .atomic)
            case .markdown: try markdown(blocks).write(to: url, atomically: true, encoding: .utf8)
            case .text: try plain(blocks).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// The recording, compressed (AAC) — a fraction of the size of the one kept.
    @MainActor static func saveAudio(_ record: MeetingRecord) {
        guard record.hasAudio, let url = ask(name: fileName(record, .all), ext: "m4a") else { return }
        let source = MeetingStore.audioURL(for: record.id)
        Task {
            do {
                guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try? FileManager.default.removeItem(at: url)       // the save panel asked about replacing it
                try await session.export(to: url, as: .m4a)
            } catch {
                await MainActor.run { fail(error) }
            }
        }
    }

    /// The conversation as subtitles: a line or two at a time, the speaker's name where
    /// a turn begins.
    @MainActor static func saveSubtitles(_ record: MeetingRecord) {
        guard let url = ask(name: fileName(record, .text), ext: "srt") else { return }
        do { try srt(record).write(to: url, atomically: true, encoding: .utf8) } catch { fail(error) }
    }

    @MainActor private static func ask(name: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor private static func fail(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Mötet kunde inte exporteras")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static func fileName(_ record: MeetingRecord, _ content: Content) -> String {
        let title = record.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return (title.isEmpty ? String(localized: "Möte") : title) + content.suffix
    }

    // MARK: The document, as blocks

    enum Block {
        case title(String)
        case meta(String)
        case heading(String)
        case paragraph(String)
        /// A list item; `done` for tasks (ticked or not), nil for the others.
        case item(String, done: Bool?)
        /// Who speaks, and when in the meeting.
        case speaker(String, at: String)
    }

    @MainActor static func blocks(_ record: MeetingRecord, _ content: Content) -> [Block] {
        let cast = record.cast
        var out: [Block] = [.title(record.title)]
        let date = record.date.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(AppLanguage.locale))
        var meta = [date, MeetingView.duration(record.duration)]
        let people = cast.order.map { cast.name(of: $0) }
        if !people.isEmpty { meta.append(people.joined(separator: ", ")) }
        out.append(.meta(meta.joined(separator: " · ")))
        if content != .text {
            if let s = record.summary {
                if !s.overview.isEmpty { out.append(.paragraph(s.overview)) }
                func section(_ title: String, _ items: [MeetingSummary.Item], tasks: Bool = false) {
                    guard !items.isEmpty else { return }
                    out.append(.heading(title))
                    for i in items {
                        out.append(.item(i.text + (i.owner.map { " (\($0))" } ?? ""), done: tasks ? (i.done == true) : nil))
                    }
                }
                section(String(localized: "Beslut"), s.decisions)
                section(String(localized: "Att göra"), s.tasks, tasks: true)
                section(String(localized: "Värt att komma ihåg"), s.points)
            }
            let own = record.notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if !own.isEmpty {
                out.append(.heading(String(localized: "Dina anteckningar")))
                for note in own {
                    out.append(.item((note.at.map { MeetingView.duration($0) + "  " } ?? "") + note.text, done: nil))
                }
            }
        }
        if content != .notes {
            if content == .all { out.append(.heading(String(localized: "Text"))) }
            for turn in MeetingText.turns(record.words) {
                let who = turn.speaker.map { $0 >= 0 ? record.name(of: $0) : "" } ?? ""
                out.append(.speaker(who, at: MeetingView.duration(turn.start)))
                out.append(.paragraph(turn.text))
            }
        }
        return out
    }

    // MARK: Text formats

    static func markdown(_ blocks: [Block]) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .title(let t): out += "# \(t)\n\n"
            case .meta(let t): out += "_\(t)_\n\n"
            case .heading(let t): out += "## \(t)\n\n"
            case .paragraph(let t): out += "\(t)\n\n"
            case .item(let t, let done):
                out += done.map { "- [\($0 ? "x" : " ")] \(t)\n" } ?? "- \(t)\n"
            case .speaker(let who, let at): out += who.isEmpty ? "**\(at)**\n\n" : "**\(who)** · \(at)\n\n"
            }
        }
        return Self.tidy(out)
    }

    static func plain(_ blocks: [Block]) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .title(let t): out += "\(t)\n"
            case .meta(let t): out += "\(t)\n\n"
            case .heading(let t): out += "\n\(t.uppercased())\n\n"
            case .paragraph(let t): out += "\(t)\n\n"
            case .item(let t, let done): out += done.map { "\($0 ? "[x]" : "[ ]") \(t)\n" } ?? "– \(t)\n"
            case .speaker(let who, let at): out += who.isEmpty ? "[\(at)]\n" : "\(who) [\(at)]\n"
            }
        }
        return Self.tidy(out)
    }

    /// A list ends with a blank line; no more than one blank line anywhere.
    private static func tidy(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var out: [String] = []
        for (i, line) in lines.enumerated() {
            let isItem = line.hasPrefix("- ") || line.hasPrefix("– ") || line.hasPrefix("[x] ") || line.hasPrefix("[ ] ")
            out.append(line)
            let next = i + 1 < lines.count ? lines[i + 1] : ""
            let nextIsItem = next.hasPrefix("- ") || next.hasPrefix("– ") || next.hasPrefix("[x] ") || next.hasPrefix("[ ] ")
            if isItem, !nextIsItem, !next.isEmpty { out.append("") }
        }
        lines = []
        for line in out where !(line.isEmpty && lines.last?.isEmpty == true) { lines.append(line) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: PDF and Word

    /// The document set in type: a serif title, quiet grey for the details, room
    /// between sections — the same look for the PDF and the Word file.
    static func document(_ blocks: [Block]) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        let ink = NSColor(white: 0.08, alpha: 1)
        let grey = NSColor(white: 0.42, alpha: 1)
        func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular, serif: Bool = false) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard serif, let d = base.fontDescriptor.withDesign(.serif) else { return base }
            return NSFont(descriptor: d, size: size) ?? base
        }
        func style(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0, line: CGFloat = 1.25) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineHeightMultiple = line
            if indent > 0 {
                p.headIndent = indent
                p.firstLineHeadIndent = 0
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            return p
        }
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            doc.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        var previous: Block?
        for block in blocks {
            switch block {
            case .title(let t):
                add(t, [.font: font(24, .regular, serif: true), .foregroundColor: ink, .paragraphStyle: style(after: 6, line: 1.1)])
            case .meta(let t):
                add(t, [.font: font(10), .foregroundColor: grey, .paragraphStyle: style(after: 18)])
            case .heading(let t):
                add(t, [.font: font(13, .semibold), .foregroundColor: ink, .paragraphStyle: style(before: 16, after: 6)])
            case .paragraph(let t):
                let afterSpeaker: Bool = { if case .speaker = previous { return true } else { return false } }()
                add(t, [.font: font(11), .foregroundColor: ink, .paragraphStyle: style(after: afterSpeaker ? 10 : 8, line: 1.3)])
            case .item(let t, let done):
                let mark = done.map { $0 ? "☑" : "☐" } ?? "•"
                add("\(mark)\t\(t)", [.font: font(11), .foregroundColor: ink, .paragraphStyle: style(after: 4, indent: 16, line: 1.3)])
            case .speaker(let who, let at):
                let line = NSMutableAttributedString(string: who.isEmpty ? "" : who + "  ",
                                                     attributes: [.font: font(10, .semibold), .foregroundColor: ink])
                line.append(NSAttributedString(string: at + "\n", attributes: [.font: font(9.5).monospacedDigits, .foregroundColor: grey]))
                line.addAttribute(.paragraphStyle, value: style(before: 4, after: 2), range: NSRange(location: 0, length: line.length))
                doc.append(line)
            }
            previous = block
        }
        return doc
    }

    /// A4 pages, set by Core Text, with the page number at the foot.
    static func pdf(_ text: NSAttributedString) -> Data {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &page, nil) else { return Data() }
        let frame = page.insetBy(dx: 64, dy: 64)
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var start = 0
        var number = 1
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: frame, transform: nil)
            let ctFrame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(ctFrame, context)
            let shown = CTFrameGetVisibleStringRange(ctFrame)
            // The page number, small, at the foot.
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor(white: 0.55, alpha: 1)])
            let line = CTLineCreateWithAttributedString(label)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: page.midX - width / 2, y: 36)
            CTLineDraw(line, context)
            context.endPDFPage()
            guard shown.length > 0 else { break }        // nothing fitted: don't loop for ever
            start += shown.length
            number += 1
        } while start < text.length
        context.closePDF()
        return data as Data
    }

    // MARK: Subtitles

    @MainActor static func srt(_ record: MeetingRecord) -> String {
        struct Cue { var start: Double; var end: Double; var text: String }
        var cues: [Cue] = []
        var current: Cue?
        var words = 0
        var speaker: Int?? = .none
        for w in record.words {
            let text = w.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let turnStarts = speaker == nil || speaker! != w.speaker
            // A new cue: a new speaker, a long one (6 s, 12 words), or after a sentence.
            if let c = current, turnStarts || w.end - c.start > 6 || words >= 12
                || (words >= 5 && (c.text.hasSuffix(".") || c.text.hasSuffix("?") || c.text.hasSuffix("!"))) {
                cues.append(c)
                current = nil
            }
            if current == nil {
                let name = turnStarts ? (w.speaker.map { $0 >= 0 ? record.name(of: $0) : "" } ?? "") : ""
                current = Cue(start: w.start, end: w.end, text: name.isEmpty ? text : "\(name): \(text)")
                words = 1
            } else {
                current!.text += " " + text
                current!.end = w.end
                words += 1
            }
            speaker = .some(w.speaker)
        }
        if let current { cues.append(current) }
        func time(_ s: Double) -> String {
            let ms = Int((max(0, s) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { i, c in
            // At least a second on screen, never into the next.
            let next = i + 1 < cues.count ? cues[i + 1].start : c.end + 2
            let end = min(max(c.end + 0.3, c.start + 1), next)
            return "\(i + 1)\n\(time(c.start)) --> \(time(end))\n\(c.text)\n"
        }
        .joined(separator: "\n")
    }
}

/// "Exportera ⌄" on a saved meeting's page.
struct ExportMenu: View {
    let record: MeetingRecord

    var body: some View {
        Menu {
            ForEach(MeetingExport.Content.allCases, id: \.self) { content in
                Menu(String(localized: content.title)) {
                    ForEach(MeetingExport.Format.allCases, id: \.self) { format in
                        Button(String(localized: format.title)) { MeetingExport.save(record, content, as: format) }
                    }
                }
                .disabled(content == .notes && record.summary == nil && record.notes.isEmpty
                          || content == .text && record.words.isEmpty)
            }
            Divider()
            Button("Ljudet (.m4a)…") { MeetingExport.saveAudio(record) }
                .disabled(!record.hasAudio)
            Button("Undertexter (.srt)…") { MeetingExport.saveSubtitles(record) }
                .disabled(record.words.isEmpty)
            Divider()
            Button("Kopiera sammanfattningen") { put(MeetingNotes.markdown(record)) }
                .disabled(record.summary == nil)
            Button("Kopiera texten") { put(MeetingText.plain(record)) }
                .disabled(record.words.isEmpty)
        } label: {
            Label("Exportera", systemImage: "square.and.arrow.up")
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(DS.Colors.chip))
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Spara mötet som PDF, Word, Markdown eller text – eller ljudet och undertexterna")
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private extension NSFont {
    var monospacedDigits: NSFont {
        let d = fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}

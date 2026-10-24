import SwiftUI

// MARK: - Floating tab bar
//
// Instead of a sidebar: a pill floating at the window's leading edge with an icon
// and a name for each page, so that Diktering, Möten and Tankar are found without
// pointing. One navigation at a time: choosing Inställningar fades the pill's pages
// out and its own sections in, under "Tillbaka" (or Esc) to the page you came from,
// with the same rows and the same black circle on the one chosen. The status line
// stays at the foot either way; in Inställningar the version sits under it, and a
// click on it shows what Om Mindtalk used to.

struct FloatingTabBar: View {
    @Binding var page: Page
    /// Where "Tillbaka" leads from Inställningar: the page you came from.
    let returnPage: Page
    @ObservedObject var dictation: Dictation
    @ObservedObject private var meeting = MeetingSession.shared
    @ObservedObject private var thoughts = Thoughts.shared
    /// Nemotron 3: without it Möten gets the same dot as Språk without its speech model.
    @ObservedObject private var voices = VoiceModels.shared
    /// The section of Inställningar on screen (SettingsPage reads the same).
    @AppStorage(SettingsSection.storageKey) private var sectionRaw = SettingsSection.general.rawValue
    @FocusState private var sectionsFocused: Bool
    @State private var showsAbout = false
    @State private var showsCredits = false
    @Namespace private var selection

    static let rowWidth: CGFloat = 196
    private var inSettings: Bool { page == .settings }
    private var section: SettingsSection { SettingsSection.preview ?? SettingsSection(stored: sectionRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The two navigations cross-fade in place; the pill takes the new one's size.
            ZStack(alignment: .topLeading) {
                if inSettings {
                    settingsNav.transition(.opacity)
                } else {
                    mainNav.transition(.opacity)
                }
            }
            Rectangle().fill(DS.Colors.divider)
                .frame(width: Self.rowWidth - 16, height: 1)
                .padding(.horizontal, 8).padding(.vertical, 6)
            status
            if inSettings { versionLine.transition(.opacity) }
        }
        .padding(8)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(DS.Colors.card)
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(DS.Colors.fieldStroke, lineWidth: 1))
        .onChange(of: inSettings) { _, now in
            // VoiceOver hears that the list beside it is another one now.
            AccessibilityNotification.Announcement(now ? String(localized: "Inställningar") : page.title).post()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in openAbout() }
        .sheet(isPresented: $showsCredits) { CreditsSheet(close: { showsCredits = false }) }
    }

    // MARK: The pages

    private var mainNav: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Page.allCases) { tab($0) }
        }
    }

    private func tab(_ p: Page) -> some View {
        let waiting = p == .recent && dictation.waiting && page != .recent
        return NavRow(icon: p.icon, title: p.title, selected: page == p, matchID: "tab", namespace: selection,
                      spoken: waiting ? String(localized: "Diktering, en text väntar") : nil) {
            guard page != p else { return }
            withAnimation(.spring(duration: 0.45, bounce: 0.15)) { page = p }
        } badge: {
            // A meeting is being recorded — visible from every page.
            if p == .meetings, meeting.isRecording {
                Circle().fill(DS.Colors.recording)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 1.5))
                    .offset(x: -3, y: 3)
                    .transition(.scale.combined(with: .opacity))
            }
            // A dictation that never got typed waits on Diktering: a small ink dot, not a count.
            if waiting {
                Circle().fill(DS.Colors.ink)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 1.5))
                    .offset(x: -4, y: 4)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        } trailing: {
            if p == .thoughts, thoughts.openCount > 0 { count(thoughts.openCount) }
        }
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 12)).monospacedDigit()
            .foregroundStyle(DS.Colors.muted)
            .transition(.opacity)
    }

    // MARK: Inställningar

    private var settingsNav: some View {
        VStack(alignment: .leading, spacing: 4) {
            NavRow(icon: "chevron.left", title: String(localized: "Tillbaka"), selected: false, matchID: "back", namespace: selection,
                   spoken: String(localized: "Tillbaka till \(backTarget.title)")) {
                goBack()
            }
            CapsLabel(String(localized: "Inställningar"))
                .padding(.leading, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases) { sectionRow($0) }
            }
            .modifier(SectionKeys(focus: $sectionsFocused, step: step))
            // Esc, wherever the focus is in the window, as Tillbaka.
            Button("") { goBack() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            // ↑ and ↓ work at once; a "Om Mindtalk" asked for on the way here opens now.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                sectionsFocused = true
                if Self.pendingAbout { Self.pendingAbout = false; showsAbout = true }
            }
        }
    }

    private func sectionRow(_ s: SettingsSection) -> some View {
        NavRow(icon: s.icon, title: s.title, selected: s == section, matchID: "section", namespace: selection) {
            sectionsFocused = true
            select(s)
        } badge: {
            if needsAttention(s) {
                Circle().fill(DS.Colors.ink)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(DS.Colors.card, lineWidth: 1.5))
                    .offset(x: -4, y: 4)
                    .accessibilityHidden(true)
            }
        } trailing: {
            EmptyView()
        }
        .accessibilityHint(needsAttention(s) ? Text("Något behöver ordnas här.") : Text(verbatim: ""))
    }

    /// The speech model isn't there, or wouldn't start: put right under Språk. The voice
    /// model the same: under Möten.
    private func needsAttention(_ s: SettingsSection) -> Bool {
        switch s {
        case .language:
            switch dictation.model {
            case .missing, .failed: return true
            default: return false
            }
        case .meetings:
            switch voices.state {
            case .missing, .failed: return true
            default: return false
            }
        default:
            return false
        }
    }

    private func select(_ s: SettingsSection) {
        guard s != section else { return }
        withAnimation(.easeOut(duration: 0.18)) { sectionRaw = s.rawValue }
    }

    /// ↑ and ↓ while the sections have focus: the one before or after.
    private func step(_ by: Int) {
        let all = SettingsSection.allCases
        guard let i = all.firstIndex(of: section), all.indices.contains(i + by) else { return }
        select(all[i + by])
    }

    /// The page you came from (Hem when Mindtalk opened on Inställningar).
    private var backTarget: Page { returnPage == .settings ? .dictation : returnPage }

    private func goBack() {
        withAnimation(.spring(duration: 0.45, bounce: 0.15)) { page = backTarget }
    }

    // MARK: Om Mindtalk

    /// "Om Mindtalk" from the menu, before the pill had turned to Inställningar.
    static var pendingAbout = false

    private func openAbout() {
        if inSettings { showsAbout = true } else { Self.pendingAbout = true }
    }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// "Mindtalk 2.0", lined up with the status's words; a click shows Om Mindtalk.
    private var versionLine: some View {
        Button { showsAbout = true } label: {
            Text(verbatim: "Mindtalk \(version)")
                .font(.system(size: 11.5))
                .foregroundStyle(DS.Colors.faint)
                .padding(.leading, 52)
                .frame(width: Self.rowWidth, height: 22, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Om Mindtalk")
        .accessibilityLabel(Text("Om Mindtalk \(version)"))
        .popover(isPresented: $showsAbout, arrowEdge: .trailing) {
            AboutPopover(version: version) {
                showsAbout = false
                AppDelegate.showIntroduction()
            } credits: {
                showsAbout = false
                showsCredits = true
            }
        }
    }

    // MARK: Status

    /// Ready or not, at the foot of the bar: a dot and a few words. While something
    /// is left to set up, a click goes to Hem, where Kom igång asks for it.
    @ViewBuilder private var status: some View {
        let row = HStack(spacing: 12) {
            // Red only while recording; otherwise ink while something is left, muted when ready.
            Circle().fill(meeting.isRecording ? DS.Colors.recording : dictation.needsSetup ? DS.Colors.ink : DS.Colors.muted)
                .frame(width: 7, height: 7)
                .frame(width: 40, height: 22)
            Text(verbatim: statusText).font(.system(size: 12)).foregroundStyle(DS.Colors.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if stepsLeft > 0, !meeting.isRecording {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Colors.muted)
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.rowWidth, alignment: .leading)
        .contentShape(Rectangle())
        if stepsLeft > 0, !meeting.isRecording {
            Button {
                withAnimation(.spring(duration: 0.45, bounce: 0.15)) { page = .dictation }
            } label: { row }
            .buttonStyle(.plain)
            .help("Visa Kom igång på Hem")
            .accessibilityLabel(Text(verbatim: statusText))
            .accessibilityHint(Text("Visar Kom igång på Hem."))
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    /// What Kom igång on Hem still asks for: the microphone, Hjälpmedel, the speech model.
    private var stepsLeft: Int {
        Self.stepsLeft(dictation)
    }

    static func stepsLeft(_ dictation: Dictation) -> Int {
        var n = 0
        if !dictation.micGranted { n += 1 }
        if !dictation.accessibilityGranted { n += 1 }
        switch dictation.model {
        case .missing, .failed, .downloading: n += 1
        case .ready, .loading: break
        }
        return n
    }

    /// What's missing, by name — "Hjälpmedel saknas", "Mikrofon saknas", "Talmodellen
    /// saknas" — or "2 steg kvar" when it's more than one. Short, and the same on Hem
    /// and in the menu bar panel.
    static func stepsText(_ dictation: Dictation) -> String {
        let n = stepsLeft(dictation)
        if n > 1 { return String(localized: "\(n) steg kvar") }
        if !dictation.accessibilityGranted { return String(localized: "Hjälpmedel saknas") }
        if !dictation.micGranted { return String(localized: "Mikrofon saknas") }
        return String(localized: "Talmodellen saknas")
    }

    private var statusText: String {
        if meeting.isRecording { return meeting.isPaused ? String(localized: "Mötet är pausat") : String(localized: "Ett möte spelas in") }
        switch dictation.model {
        case .downloading(let p) where SpeechModel.isPreparing(p): return String(localized: "Förbereder…")
        case .downloading(let p): return String(localized: "Laddar ned \(Int(min(1, p / 0.9) * 100)) %")
        default:
            // What you must do comes before what Mindtalk is busy with.
            if stepsLeft > 0 { return Self.stepsText(dictation) }
            return dictation.model == .loading ? String(localized: "Startar…") : String(localized: "Redo")
        }
    }
}

extension Notification.Name {
    /// Show Om Mindtalk: the popover from the version line in Inställningar.
    static let showAbout = Notification.Name("MindtalkShowAbout")
}

/// One row of the pill: the icon in a 40-point circle (filled ink when chosen), the
/// name, and what trails it.
private struct NavRow<Badge: View, Trailing: View>: View {
    let icon: String
    let title: String
    let selected: Bool
    let matchID: String
    let namespace: Namespace.ID
    /// What VoiceOver says, when it isn't the title.
    var spoken: String? = nil
    let action: () -> Void
    @ViewBuilder var badge: Badge
    @ViewBuilder var trailing: Trailing

    init(icon: String, title: String, selected: Bool, matchID: String, namespace: Namespace.ID,
         spoken: String? = nil,
         action: @escaping () -> Void,
         @ViewBuilder badge: () -> Badge = { EmptyView() },
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.selected = selected
        self.matchID = matchID
        self.namespace = namespace
        self.spoken = spoken
        self.action = action
        self.badge = badge()
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? DS.Colors.onInk : .primary)
                    .frame(width: 40, height: 40)
                    .background {
                        if selected {
                            Circle().fill(DS.Colors.accent)
                                .matchedGeometryEffect(id: matchID, in: namespace)
                        }
                    }
                    .overlay(alignment: .topTrailing) { badge }
                Text(verbatim: title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.trailing, 12)
            .frame(width: FloatingTabBar.rowWidth, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(TabHoverStyle())
        .accessibilityLabel(Text(verbatim: spoken ?? title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// ↑ and ↓ move between the sections while they have focus. A click on one gives
/// them focus.
private struct SectionKeys: ViewModifier {
    var focus: FocusState<Bool>.Binding
    let step: (Int) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(focus)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .onKeyPress(.downArrow) { step(1); return .handled }
    }
}

/// Om Mindtalk, from the version line: who makes it, the introduction again, and
/// the credits — the models and code Mindtalk is built on — in a sheet.
private struct AboutPopover: View {
    let version: String
    let introduction: () -> Void
    let credits: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Mindtalk \(version)").font(.system(size: 15, weight: .semibold))
                Text(verbatim: "© 2026 Mindact Solutions AB").font(.system(size: 12.5)).foregroundStyle(DS.Colors.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Visa introduktionen", action: introduction).buttonStyle(.soft)
                Button("Tack till och licenser…", action: credits).buttonStyle(.soft)
            }
        }
        .padding(18)
        .frame(minWidth: 240, alignment: .leading)
    }
}

/// A soft light under the row you point at.
private struct TabHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Capsule().fill(DS.Colors.chip.opacity(hovering ? 0.7 : 0)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(duration: 0.18), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

import SwiftUI
import UIKit
import AVFoundation

extension Binding where Value == Bool {
    // Presence binding for alert(isPresented:presenting:) pairs.
    init<T>(isPresent source: Binding<T?>) {
        self.init(get: { source.wrappedValue != nil },
                  set: { if !$0 { source.wrappedValue = nil } })
    }
}

extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

@MainActor
enum Keyboard {
    // Screens that keep the keyboard up permanently (the quiz) flip this on
    // so the window-level dismiss tap stands down.
    static var suppressTapDismiss = false

    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    // Window-level tap: hides the keyboard on any tap without stealing
    // touches from buttons and rows (cancelsTouchesInView = false).
    static func installTapToDismiss() {
        guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              window.gestureRecognizers?.contains(where: { $0.name == tapName }) != true
        else { return }
        let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing))
        tap.name = tapName
        tap.cancelsTouchesInView = false
        tap.delegate = TapDelegate.shared
        window.addGestureRecognizer(tap)
    }

    private static let tapName = "keyboard-dismiss-tap"

    private final class TapDelegate: NSObject, UIGestureRecognizerDelegate {
        static let shared = TapDelegate()
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // Taps inside a text input must keep their normal caret/selection
        // behavior instead of bouncing the keyboard.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if Keyboard.suppressTapDismiss { return false }
            var view = touch.view
            while let current = view {
                if current is UITextField || current is UITextView { return false }
                view = current.superview
            }
            return true
        }
    }
}

@MainActor
final class SpeechService {
    static let shared = SpeechService()
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionConfigured = false

    func speak(_ text: String) {
        if !sessionConfigured {
            // .playback so words are audible with the silent switch on.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio,
                                                             options: .duckOthers)
            try? AVAudioSession.sharedInstance().setActive(true)
            sessionConfigured = true
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        synthesizer.speak(utterance)
    }
}

struct SpeakButton: View {
    let text: String

    var body: some View {
        Button {
            SpeechService.shared.speak(text)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
    }
}

enum WordLink {
    static let scheme = "wordace"

    private static let skip: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "with",
        "or", "and", "is", "are", "was", "were", "be", "been", "being", "it",
        "its", "as", "from", "that", "this", "these", "those", "he", "she",
        "they", "them", "him", "his", "her", "their", "you", "your", "we",
        "our", "i", "me", "my", "us", "not", "no", "but", "if", "so", "than",
        "then", "into", "onto", "one", "who", "which", "when", "where", "how",
        "what", "there", "here", "up", "out", "off", "over", "down", "about",
        "such", "any", "all", "some", "etc", "has", "have", "had", "does",
        "do", "did", "can", "may", "will", "would", "should", "could",
    ]

    static func url(for lemma: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "word"
        components.path = "/" + lemma
        return components.url
    }

    static func lemma(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == "word" else { return nil }
        let lemma = url.path.dropFirst()
        return lemma.isEmpty ? nil : String(lemma)
    }

    static func isCandidate(_ token: String) -> Bool {
        token.count >= 3 && !skip.contains(token)
    }

    // Inflections resolve to base lemmas ("having" -> "have"), so the skip
    // list must also veto the resolved target, not just the surface token.
    static func isLinkTarget(_ lemma: String) -> Bool {
        !skip.contains(lemma)
    }

    // Shared parse-and-fallback policy for wordace:// links.
    static func openURLAction(_ open: @escaping (String) -> Void) -> OpenURLAction {
        OpenURLAction { url in
            guard let lemma = lemma(from: url) else { return .systemAction }
            open(lemma)
            return .handled
        }
    }
}

// Text whose dictionary words are tappable links (wordace://word/<lemma>).
// Handle taps with .environment(\.openURL, OpenURLAction { ... }).
struct LinkedText: View {
    let text: String
    let color: Color
    var excluding: String? = nil

    private struct Linked {
        let text: String
        let attributed: AttributedString
    }

    @State private var linked: Linked?

    var body: some View {
        Text(displayed)
            .task(id: text) {
                let attributed = await linkify()
                // A restarted task (text changed) owns the state now; a stale
                // result must not land after it — resolveTokens' queue hop
                // resumes even for cancelled tasks.
                guard !Task.isCancelled else { return }
                linked = Linked(text: text, attributed: attributed)
            }
    }

    // Never render a cached string built from different text.
    private var displayed: AttributedString {
        if let linked, linked.text == text { return linked.attributed }
        return AttributedString(text)
    }

    private func linkify() async -> AttributedString {
        var segments: [(text: String, token: String?)] = []
        var current = ""
        var word = ""

        func flushWord() {
            if !word.isEmpty {
                // Straight quotes for lookup: lemmas and the "'s" strip in
                // resolveTokenLocked use ASCII apostrophes.
                segments.append((word, word.lowercased().straightApostrophes))
                word = ""
            }
        }
        func flushPlain() {
            if !current.isEmpty {
                segments.append((current, nil))
                current = ""
            }
        }

        for ch in text {
            if ch.isLetter || ch == "'" || ch == "’" {
                flushPlain()
                word.append(ch)
            } else {
                flushWord()
                current.append(ch)
            }
        }
        flushWord()
        flushPlain()

        let candidates = Set(segments.compactMap { $0.token }.filter {
            WordLink.isCandidate($0) && $0 != excluding
        })
        let resolved = candidates.isEmpty
            ? [:]
            : await DictionaryService.shared.resolveTokens(candidates)

        var out = AttributedString()
        for segment in segments {
            var run = AttributedString(segment.text)
            run.foregroundColor = color
            if let token = segment.token,
               let lemma = resolved[token],
               lemma != excluding,
               WordLink.isLinkTarget(lemma),
               let url = WordLink.url(for: lemma) {
                run.link = url
            }
            out.append(run)
        }
        return out
    }
}

// Icon-derived palette. The app pins one appearance (dark canvas, lifted
// gray cards, gold accents) and never follows the system scheme.
extension Color {
    static let appBackground = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let cardSurface = Color(red: 0.24, green: 0.24, blue: 0.27)
}

extension View {
    // Every screen sits on the same icon-gray canvas; List/Form default
    // backgrounds are hidden so the canvas shows through. Nav and tab bars
    // keep the system glass: iOS 26 ignores toolbarBackground for both, and
    // over the uniform canvas the glass reads close to solid (accepted).
    func appScreen() -> some View {
        self
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
    }

    // Default grouped rows resolve darker than the canvas; lift them to cards.
    func cardSurfaceRow() -> some View {
        listRowBackground(Color.cardSurface)
    }
}

// The one card-glow visual: tint wash + bright border on the card shape.
struct CardGlow: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(color.opacity(0.12))
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(color, lineWidth: 2)
        }
    }
}

// Card drawn inside the row content (system row background stays clear):
// swipe actions then drag the finished card instead of unmasking a square
// row. Use on any single-row section that carries swipeActions.
extension View {
    func cardRow(color: Color? = nil) -> some View {
        self
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Color.cardSurface)
                    if let color {
                        CardGlow(color: color)
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// Card row that pushes a value on tap; the chevron is ours because the
// system accessory would sit outside the card.
struct CardLinkRow<Value: Hashable, Content: View>: View {
    let value: Value
    var color: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            NavigationLink(value: value) { EmptyView() }.opacity(0)
            HStack {
                content
                Spacer()
                RowChevron()
            }
        }
        .cardRow(color: color)
    }
}

// Chevron accessory for card rows that push via a hidden NavigationLink
// (the system accessory would sit outside the card).
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

// Backdrop for a single-row section card; the glow only lines up with the
// card edge when the row is alone in its section.
struct RowGlow: View {
    let color: Color?

    var body: some View {
        ZStack {
            Color.cardSurface
            if let color {
                CardGlow(color: color)
            }
        }
    }
}

extension Medal {
    var color: Color {
        switch self {
        case .bronze: return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver: return Color(red: 0.60, green: 0.65, blue: 0.70)
        case .gold: return .yellow
        }
    }
}

// The three medal slots: dim until the best attempt reaches each threshold.
struct MedalRow: View {
    let bestPercent: Int
    var font: Font = .body

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Medal.allCases, id: \.rawValue) { medal in
                Image(systemName: "medal.fill")
                    .font(font)
                    .foregroundStyle(bestPercent >= medal.threshold
                                     ? medal.color
                                     : Color.white.opacity(0.25))
            }
        }
    }
}

struct TagBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.22))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

// The app-wide button: a capsule that is solid when active/primary and lightly
// tinted otherwise, pressed-in via a slight scale.
struct CapsuleButton: View {
    let title: String
    var systemImage: String? = nil
    var isOn: Bool = true
    var color: Color = .accentColor
    var isDisabled: Bool = false
    var isLarge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(isLarge ? .headline : .subheadline.weight(.semibold))
            .foregroundStyle(isDisabled ? Color.secondary : (isOn ? .white : color))
            .frame(maxWidth: .infinity)
            .padding(.vertical, isLarge ? 12 : 7)
            .background(isDisabled ? Color.white.opacity(0.08) : (isOn ? color : color.opacity(0.22)))
            // The tint washes are see-through on their own; scrolling cards
            // must not show through the capsule.
            .background(Color.appBackground)
            .clipShape(Capsule())
        }
        .buttonStyle(SolidPressStyle())
        .scaleEffect(isOn && !isDisabled ? 0.97 : 1)
        .animation(.spring(duration: 0.25), value: isOn)
        .disabled(isDisabled)
    }
}

// Press feedback without the system opacity fade: the capsule stays solid
// and just compresses slightly.
private struct SolidPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct BottomCTA: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        CapsuleButton(title: title, systemImage: systemImage, isLarge: true, action: action)
            .padding(.horizontal)
            .padding(.bottom, 8)
    }
}

struct DisclosureRow: View {
    let title: String
    var subtitle: String? = nil
    var titleIsHeadline: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(titleIsHeadline ? .headline : .body)
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// Telegram-style spoiler: the word keeps its exact place in the line (the
// text is always laid out, just transparent) under a veil of shimmering dust
// that scatters away on tap; tapping again gathers it back.
struct SpoilerText: View {
    private enum Phase: Equatable {
        case hidden
        case dissolving(Date)
        case settled
    }

    let text: String
    @State private var phase: Phase = .hidden

    private static let dissolve: TimeInterval = 0.45

    var body: some View {
        // The timeline only runs during the dissolve itself: the resting
        // veil is static white dust, the settled word is plain text.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isDissolving)) { timeline in
            let progress = dissolveProgress(at: timeline.date)
            Text(text)
                .opacity(progress)
                // The frame comes BEFORE the overlay so the veil covers the
                // widened slot: short words must not betray their length.
                .frame(minWidth: 60, alignment: .leading)
                .overlay {
                    SpoilerDust(dissolve: progress)
                        .allowsHitTesting(false)
                }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            phase = phase == .hidden ? .dissolving(Date()) : .hidden
        }
        .task(id: phase) {
            guard case .dissolving = phase else { return }
            try? await Task.sleep(for: .seconds(Self.dissolve))
            if !Task.isCancelled, case .dissolving = phase {
                phase = .settled
            }
        }
    }

    private var isDissolving: Bool {
        if case .dissolving = phase { return true }
        return false
    }

    // Settled renders the final state directly: a paused timeline may hold a
    // stale frame date, and computing from it would freeze mid-dissolve.
    private func dissolveProgress(at now: Date) -> Double {
        switch phase {
        case .hidden: return 0
        case .settled: return 1
        case .dissolving(let start):
            return min(1, now.timeIntervalSince(start) / Self.dissolve)
        }
    }
}

// One card per element with the section title above the first row only —
// the app-wide list shape.
struct CardSections<Element, ID: Hashable, Row: View>: View {
    private struct Indexed: Identifiable {
        let index: Int
        let element: Element
        let id: ID
    }

    private let title: String
    private let indexed: [Indexed]
    @ViewBuilder private let row: (Element) -> Row

    init(_ title: String, items: [Element], id: (Element) -> ID,
         @ViewBuilder row: @escaping (Element) -> Row) {
        self.title = title
        self.indexed = items.enumerated().map {
            Indexed(index: $0.offset, element: $0.element, id: id($0.element))
        }
        self.row = row
    }

    var body: some View {
        ForEach(indexed) { item in
            Section {
                row(item.element)
            } header: {
                if item.index == 0 {
                    Text(title)
                }
            }
            .cardSurfaceRow()
        }
    }
}

// The one "Translation:" row, spoiler included.
struct TranslationRow: View {
    let translation: String?

    var body: some View {
        if let translation = translation?.nilIfEmpty {
            HStack(spacing: 6) {
                Text("Translation:")
                    .foregroundStyle(Color.secondary)
                SpoilerText(text: translation)
            }
            .font(.footnote)
        }
    }
}

// The dust itself: deterministic plain-white particles that drift outward
// and fade as the dissolve progresses.
struct SpoilerDust: View {
    let dissolve: Double

    var body: some View {
        Canvas { context, size in
            var rng = SplitMix(seed: 0x5EED)
            let base = 0.85 * (1 - dissolve)
            guard base > 0.01 else { return }

            // Smoothstep to fully transparent at the border.
            func fade(_ distance: CGFloat, _ feather: CGFloat) -> Double {
                let t = max(0, min(1, distance / feather))
                return Double(t * t * (3 - 2 * t))
            }

            // Stratified jittered grid instead of pure random: even coverage,
            // no bald patches.
            let cell: CGFloat = 3.5
            let cols = max(1, Int(size.width / cell))
            let rows = max(1, Int(size.height / cell))
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            for row in 0..<rows {
                for col in 0..<cols {
                    let baseX = (CGFloat(col) + 0.15 + 0.7 * rng.next()) * cellW
                    let baseY = (CGFloat(row) + 0.15 + 0.7 * rng.next()) * cellH
                    let radius = 0.6 + rng.next() * 0.8
                    let angle = rng.next() * 2 * .pi
                    let flight = dissolve * (10 + rng.next() * 22)
                    let x = baseX + cos(angle) * flight
                    let y = baseY + sin(angle) * flight
                    let xFade = fade(min(baseX, size.width - baseX), 16)
                    let yFade = fade(min(baseY, size.height - baseY), max(4, size.height * 0.4))
                    let alpha = base * xFade * yFade * (0.7 + 0.3 * rng.next())
                    guard alpha > 0.02 else { continue }
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                               width: radius * 2, height: radius * 2)),
                        with: .color(.white.opacity(alpha)))
                }
            }
        }
    }
}

// Deterministic per-frame randomness: the same seed must place the same
// particles on every redraw, or the dust would boil chaotically.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64.max >> 11)
    }
}

// Rounded stat card for the profile and stats grids.
struct StatTile: View {
    let value: String
    let label: String
    var icon: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.2))
                    .clipShape(Circle())
            }
            Text(value)
                .font(.system(.title2, design: .rounded).bold())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// Keeps the last list rows reachable above a floating BottomCTA.
struct ListBottomSpacer: View {
    var height: CGFloat = 72

    var body: some View {
        // Its own section: joining the preceding implicit section would move
        // that card's rounded bottom corners onto this invisible row.
        Section {
            Color.clear
                .frame(height: height)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

// Shared "Progress · n/m learned" plate used by the word and group pages.
struct ProgressPlateSection: View {
    let learned: Int
    let total: Int

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Progress").font(.headline)
                    Spacer()
                    Text("\(learned)/\(total) learned")
                        .font(.subheadline)
                        .foregroundStyle(learned > 0 ? Color.green : Color.secondary)
                }
                ProgressView(value: Double(learned), total: Double(max(total, 1)))
                    .tint(.green)
            }
            .listRowBackground(RowGlow(color: learned == total && total > 0 ? .green : nil))
        }
    }
}

// Shared quiz answer row (summary list and saved-session detail).
struct AnswerRow: View {
    let isCorrect: Bool
    let title: String
    let subtitle: String
    var typed: String? = nil

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isCorrect ? .green : .red)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline).bold()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let typed, !isCorrect, !typed.isBlank {
                    Text("You typed: \(typed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(Color.cardSurface)
    }
}

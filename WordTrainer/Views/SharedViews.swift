import SwiftUI

enum WordLink {
    static let scheme = "wordtrainer"

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

    // Shared parse-and-fallback policy for wordtrainer:// links.
    static func openURLAction(_ open: @escaping (String) -> Void) -> OpenURLAction {
        OpenURLAction { url in
            guard let lemma = lemma(from: url) else { return .systemAction }
            open(lemma)
            return .handled
        }
    }
}

// Text whose dictionary words are tappable links (wordtrainer://word/<lemma>).
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
                segments.append((word, word.lowercased().replacingOccurrences(of: "’", with: "'")))
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

struct TagBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

struct BottomCTA: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
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
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// Keeps the last list rows reachable above a floating BottomCTA.
struct ListBottomSpacer: View {
    var body: some View {
        Color.clear
            .frame(height: 72)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

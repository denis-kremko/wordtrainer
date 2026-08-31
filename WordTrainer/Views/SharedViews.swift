import SwiftUI

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

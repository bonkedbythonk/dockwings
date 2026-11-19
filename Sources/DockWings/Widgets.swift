// Shared pieces every widget uses: the rise-in transition and the two-line
// label, so all widgets look and move alike.
import SwiftUI

extension AnyTransition {
    /// Rises out of the Dock's baseline: grows from the bottom, sharpens and
    /// fades in; leaves the same way.
    static var rise: AnyTransition { .modifier(active: Rise(shown: false), identity: Rise(shown: true)) }
}

private struct Rise: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.7, anchor: .bottom)
            .offset(y: shown ? 0 : 24)
            .blur(radius: shown ? 0 : 8)
            .opacity(shown ? 1 : 0)
    }
}

/// Bold first line, dimmer second line, both truncating.
struct Lines: View {
    let title: String
    let subtitle: String
    var maxWidth: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(ink(0.6))
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .hug(max: maxWidth)
    }
}

/// Rounded tile the size of a small Dock icon, for widget glyphs.
struct Tile<Content: View>: View {
    var side: CGFloat = 40
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(Color(white: 0.18))
            content()
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
    }
}

/// Relative time like "just now", "3m ago".
func ago(_ date: Date) -> String {
    let seconds = Int(-date.timeIntervalSinceNow)
    if seconds < 45 { return "just now" }
    if seconds < 3600 { return "\(max(1, seconds / 60))m ago" }
    return "\(seconds / 3600)h ago"
}

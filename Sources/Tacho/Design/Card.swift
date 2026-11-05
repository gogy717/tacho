import SwiftUI

/// How much a sentence asks of the reader. Amber and red are for limits and left-out figures only.
enum Tone: Equatable {
    case plain, warning, critical

    var color: Color {
        switch self {
        case .plain: .secondary
        case .warning: Theme.amberInk
        case .critical: Theme.redInk
        }
    }
}

/// A plain sentence on a card.
struct Say: View {
    let text: String
    var tone = Tone.plain

    init(_ text: String, tone: Tone = .plain) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(Theme.Style.caption)
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A card's title, anything it wants on the right, and a chevron when it opens something.
struct CardHeader<Trailing: View>: View {
    let title: String
    var opens = false
    let trailing: Trailing

    init(_ title: String, opens: Bool = false, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.opens = opens
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(Theme.Style.cardTitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            trailing
            if opens {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The surface everything sits on. With an `action` the whole card is a button, which opens its detail.
struct Card<Content: View>: View {
    enum Size {
        case regular, small

        var padding: EdgeInsets {
            switch self {
            case .regular: Theme.Size.cardPadding
            case .small: Theme.Size.smallCardPadding
            }
        }

        var gap: CGFloat {
            switch self {
            case .regular: 4
            case .small: 1
            }
        }
    }

    var size = Size.regular
    var action: (() -> Void)?
    @ViewBuilder let content: Content

    private var surface: some View {
        VStack(alignment: .leading, spacing: size.gap) { content }
            .padding(size.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        if let action {
            HoverButton(action: action) { surface }
        } else {
            surface.background(Theme.tile, in: Self.shape)
        }
    }

    fileprivate static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Size.cardRadius, style: .continuous)
    }
}

private struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(CardButtonStyle())
    }
}

/// A hovered card and a pressed one read the same: spec §4.3.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardFace(isPressed: configuration.isPressed) { configuration.label }
    }
}

private struct CardFace<Label: View>: View {
    @State private var isHovering = false

    let isPressed: Bool
    @ViewBuilder let label: Label

    var body: some View {
        label
            .background(isHovering || isPressed ? Theme.hover : Theme.tile, in: Card<EmptyView>.shape)
            .contentShape(Card<EmptyView>.shape)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

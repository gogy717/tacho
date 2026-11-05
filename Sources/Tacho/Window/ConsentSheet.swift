import SwiftUI

/// Asks before Tacho sends anything, saying what spec §5.6 says: what is read, where it goes, and how often.
struct ConsentSheet: View {
    let answer: (_ allow: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "consent.title", bundle: .tacho))
                .font(.title3.weight(.semibold))
            ConsentFacts()
            HStack {
                Spacer()
                Button(String(localized: "consent.decline", bundle: .tacho)) { answer(false) }
                    .keyboardShortcut(.cancelAction)
                // No default button: a stray Return must not agree to a Keychain read.
                Button(String(localized: "consent.allow", bundle: .tacho)) { answer(true) }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

/// What the Anthropic query does, the same words wherever it is offered.
struct ConsentFacts: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("consent.readTitle", "consent.read")
            fact("consent.sentTitle", "consent.sent")
            fact("consent.oftenTitle", "consent.often")
            fact("consent.keptTitle", "consent.kept")
        }
    }

    private func fact(_ title: String.LocalizationValue, _ text: String.LocalizationValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: title, bundle: .tacho))
                .font(.callout.weight(.medium))
            Text(String(localized: text, bundle: .tacho))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

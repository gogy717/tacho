import AppKit
import SwiftUI
import TachoKit

/// The gauge in the menu bar, and the figure beside it.
struct MenuBarLabel: View {
    private static let symbol = "gauge.with.needle"

    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon(alert: model.dashboard?.alert ?? .none))
            if let title = Self.title(dashboard: model.dashboard, preferences: model.preferences) {
                Text(title)
            }
        }
    }

    static func title(dashboard: Dashboard?, preferences: Preferences) -> String? {
        guard let dashboard else { return nil }
        switch preferences.menuBarStyle {
        case .rate:
            // While the recent logs are being read the figure is not known yet.
            return dashboard.isIdle || dashboard.progress.isReadingNewest ? nil : Labels.rate(dashboard, mode: preferences.rateMode, unit: preferences.rateUnit)
        case .iconOnly:
            return nil
        case .fiveHourPercent:
            let quota = dashboard.quotas.first {
                $0.snapshot.provider == .anthropic && $0.snapshot.window == .fiveHour && $0.snapshot.scope == nil
            }
            return quota.flatMap(Labels.percent)
        }
    }

    /// A template follows the menu bar's own colour, so a warning has to be an image that is not one.
    static func icon(alert: AlertLevel) -> NSImage {
        let size = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let description: String
        let configuration: NSImage.SymbolConfiguration
        switch alert {
        case .none:
            description = String(localized: "menuBar.icon", bundle: .tacho)
            configuration = size
        case .amber:
            description = String(localized: "menuBar.iconAmber", bundle: .tacho)
            configuration = size.applying(.init(paletteColors: [.systemOrange]))
        case .red:
            description = String(localized: "menuBar.iconRed", bundle: .tacho)
            configuration = size.applying(.init(paletteColors: [.systemRed]))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = alert == .none
        return image
    }
}

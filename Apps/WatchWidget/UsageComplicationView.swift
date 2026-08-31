import SwiftUI
import WidgetKit
import WatchUI

struct UsageComplicationView: View {
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.widgetContentMargins) private var widgetContentMargins
    let entry: UsageTimelineEntry

    var body: some View {
        Group {
            if let accounts = entry.snapshot?.accounts, !accounts.isEmpty {
                UsageColumnsView(
                    accounts: accounts,
                    now: entry.date,
                    allowsSemanticColors: renderingMode == .fullColor
                )
            } else {
                VStack(spacing: 2) {
                    Text("--%")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                    Text("IPHONE-APP ÖFFNEN")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Keine Codex-Nutzungsdaten. iPhone-App öffnen.")
            }
        }
        .padding(.horizontal, horizontalContentMargin)
        .padding(.vertical, verticalContentMargin)
        .widgetAccentable()
    }

    /// The configuration disables WidgetKit's automatic inset so the three-
    /// account layout can use the rectangular area. Reapply a small, bounded
    /// safe inset here rather than depending on device-specific defaults.
    private var horizontalContentMargin: CGFloat {
        min(max(min(widgetContentMargins.leading, widgetContentMargins.trailing), 1), 2)
    }

    private var verticalContentMargin: CGFloat {
        min(max(min(widgetContentMargins.top, widgetContentMargins.bottom), 0.5), 1)
    }
}

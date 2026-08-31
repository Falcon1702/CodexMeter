import SwiftUI
import UIKit
import UsageCore
import WatchUI
import WidgetKit

struct PhoneUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: PhoneUsageTimelineEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                Color(uiColor: .systemBackground)
            }
            .widgetAccentable()
    }

    @ViewBuilder
    private var content: some View {
        if let accounts = entry.snapshot?.accounts, !accounts.isEmpty {
            switch family {
            case .systemSmall:
                UsageHomeWidgetView(
                    accounts: accounts,
                    now: entry.date,
                    style: .small,
                    allowsSemanticColors: allowsSemanticColors
                )
                .padding(12)
            case .systemMedium:
                UsageHomeWidgetView(
                    accounts: accounts,
                    now: entry.date,
                    style: .medium,
                    allowsSemanticColors: allowsSemanticColors
                )
                .padding(12)
            case .accessoryRectangular:
                UsageColumnsView(
                    accounts: accounts,
                    now: entry.date,
                    allowsSemanticColors: allowsSemanticColors
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            default:
                EmptyView()
            }
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch family {
        case .systemSmall, .systemMedium:
            VStack(spacing: 5) {
                Text("--%")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                Text("IPHONE-APP ÖFFNEN")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .accessoryRectangular:
            VStack(spacing: 2) {
                Text("--%")
                    .font(.system(size: 25, weight: .heavy, design: .rounded))
                Text("IPHONE-APP ÖFFNEN")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            EmptyView()
        }
    }

    private var allowsSemanticColors: Bool {
        renderingMode == .fullColor
    }
}

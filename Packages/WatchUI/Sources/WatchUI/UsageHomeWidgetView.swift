import SwiftUI
import UsageCore

public enum UsageHomeWidgetStyle: Sendable {
    case small
    case medium
}

public struct UsageHomeWidgetView: View {
    public let accounts: [UsageAccount]
    public let now: Date
    public let style: UsageHomeWidgetStyle
    public var allowsSemanticColors: Bool

    public init(
        accounts: [UsageAccount],
        now: Date,
        style: UsageHomeWidgetStyle,
        allowsSemanticColors: Bool = true
    ) {
        self.accounts = accounts
        self.now = now
        self.style = style
        self.allowsSemanticColors = allowsSemanticColors
    }

    private var visibleAccounts: [UsageAccount] {
        Array(accounts.prefix(3))
    }

    public var body: some View {
        Group {
            switch style {
            case .small:
                smallLayout
            case .medium:
                mediumLayout
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var smallLayout: some View {
        if let account = visibleAccounts.first, visibleAccounts.count == 1 {
            accountTile(account, metrics: .smallSingle)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                    accountTile(
                        account,
                        metrics: visibleAccounts.count == 2 ? .smallPair : .smallTriple
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if index < visibleAccounts.count - 1 {
                        Divider()
                            .overlay(.secondary.opacity(0.25))
                    }
                }
            }
        }
    }

    private var mediumLayout: some View {
        HStack(spacing: 0) {
            ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                accountTile(account, metrics: mediumMetrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if index < visibleAccounts.count - 1 {
                    Divider()
                        .overlay(.secondary.opacity(0.25))
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private var mediumMetrics: Metrics {
        switch visibleAccounts.count {
        case 1: .mediumSingle
        case 2: .mediumPair
        default: .mediumTriple
        }
    }

    private func accountTile(
        _ account: UsageAccount,
        metrics: Metrics
    ) -> some View {
        GeometryReader { proxy in
            let topHeight = proxy.size.height / 3

            VStack(spacing: 0) {
                HStack(spacing: metrics.gap) {
                    UsageServiceMarkView(
                        brand: account.serviceBrand,
                        fallback: account.displayName
                    )
                    .frame(width: metrics.mark, height: metrics.mark)

                    Text(compactCountdown(for: account))
                        .font(.system(
                            size: metrics.countdown,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.45)
                        .allowsTightening(true)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: topHeight, maxHeight: topHeight)

                Text("\(account.displayRemainingPercent)%")
                    .font(.system(
                        size: metrics.percentage,
                        weight: .heavy,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .minimumScaleFactor(0.42)
                    .allowsTightening(true)
                    .lineLimit(1)
                    .foregroundStyle(color(for: account.severity))
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: account))
        .accessibilityValue(accessibilityValue(for: account))
    }

    private func compactCountdown(for account: UsageAccount) -> String {
        ResetCountdownFormatter.string(until: account.resetsAt, now: now)
            .replacingOccurrences(of: " ", with: "")
    }

    private func accessibilityLabel(for account: UsageAccount) -> String {
        "\(account.displayName), \(account.displayRemainingPercent) Prozent verbleibend, Reset in \(ResetCountdownFormatter.string(until: account.resetsAt, now: now))"
    }

    private func accessibilityValue(for account: UsageAccount) -> String {
        let status: String
        switch account.severity {
        case .healthy: status = "Kontingent verfügbar"
        case .warning: status = "Kontingent knapp"
        case .critical: status = "Kontingent kritisch"
        }

        return account.stale
            ? "\(status), Daten möglicherweise veraltet"
            : "\(status), Aktuell"
    }

    private func color(for severity: UsageSeverity) -> Color {
        guard allowsSemanticColors else { return .primary }
        switch severity {
        case .healthy: return .accentColor
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    private struct Metrics {
        let mark: CGFloat
        let countdown: CGFloat
        let percentage: CGFloat
        let gap: CGFloat
        let horizontalPadding: CGFloat

        static let smallSingle = Metrics(
            mark: 24,
            countdown: 15,
            percentage: 70,
            gap: 5,
            horizontalPadding: 5
        )
        static let smallPair = Metrics(
            mark: 15,
            countdown: 10,
            percentage: 38,
            gap: 3,
            horizontalPadding: 3
        )
        static let smallTriple = Metrics(
            mark: 11,
            countdown: 8,
            percentage: 26,
            gap: 2,
            horizontalPadding: 2
        )
        static let mediumSingle = Metrics(
            mark: 28,
            countdown: 18,
            percentage: 76,
            gap: 6,
            horizontalPadding: 10
        )
        static let mediumPair = Metrics(
            mark: 23,
            countdown: 15,
            percentage: 68,
            gap: 4,
            horizontalPadding: 8
        )
        static let mediumTriple = Metrics(
            mark: 18,
            countdown: 12,
            percentage: 50,
            gap: 3,
            horizontalPadding: 5
        )
    }
}

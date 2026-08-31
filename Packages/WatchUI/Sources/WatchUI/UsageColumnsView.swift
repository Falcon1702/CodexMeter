import SwiftUI
import UsageCore

public struct UsageColumnsView: View {
    public let accounts: [UsageAccount]
    public let now: Date
    public var allowsSemanticColors: Bool

    public init(
        accounts: [UsageAccount],
        now: Date,
        allowsSemanticColors: Bool = true
    ) {
        self.accounts = accounts
        self.now = now
        self.allowsSemanticColors = allowsSemanticColors
    }

    private var visibleAccounts: [UsageAccount] {
        Array(accounts.prefix(3))
    }

    public var body: some View {
        GeometryReader { proxy in
            let layout = ContainerMetrics(
                size: proxy.size,
                accountCount: visibleAccounts.count
            )

            HStack(spacing: 0) {
                ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                    accountTile(
                        account,
                        size: layout.tileSize
                    )
                    .frame(
                        width: layout.tileSize.width,
                        height: layout.tileSize.height
                    )

                    if index < visibleAccounts.count - 1 {
                        Rectangle()
                            .fill(.secondary.opacity(0.32))
                            .frame(width: layout.separatorWidth)
                            .padding(.vertical, layout.separatorInset)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .contain)
    }

    private func accountTile(
        _ account: UsageAccount,
        size: CGSize
    ) -> some View {
        let metrics = tileMetrics(for: size)
        let topHeight = size.height / 3

        return VStack(spacing: 0) {
            HStack(spacing: metrics.gap) {
                UsageServiceMarkView(
                    brand: account.serviceBrand,
                    fallback: account.displayName
                )
                .frame(width: metrics.mark, height: metrics.mark)

                Text(compactCountdown(for: account))
                    .font(.system(
                        size: metrics.countdown,
                        weight: .bold,
                        design: .rounded
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.75)
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

    private func tileMetrics(for size: CGSize) -> TileMetrics {
        let baseline: TileMetrics
        let baselineWidth: CGFloat

        switch visibleAccounts.count {
        case 1:
            baselineWidth = 170
            baseline = TileMetrics(
                mark: 20,
                countdown: 17,
                percentage: 40,
                gap: 5,
                horizontalPadding: 5
            )
        case 2:
            baselineWidth = 84.5
            baseline = TileMetrics(
                mark: 18,
                countdown: 14,
                percentage: 35,
                gap: 3,
                horizontalPadding: 3
            )
        default:
            baselineWidth = 56
            baseline = TileMetrics(
                mark: 15,
                countdown: 11,
                percentage: 27,
                gap: 2,
                horizontalPadding: 1
            )
        }

        return baseline.scaled(
            by: layoutScale(for: size, baselineWidth: baselineWidth)
        )
    }

    private func layoutScale(for size: CGSize, baselineWidth: CGFloat) -> CGFloat {
        let widthScale = size.width / baselineWidth
        let heightScale = size.height / 64
        return max(0.1, min(min(widthScale, heightScale), 1.2))
    }

    private func color(for severity: UsageSeverity) -> Color {
        guard allowsSemanticColors else { return .primary }
        switch severity {
        case .healthy: return Color.accentColor
        case .warning: return Color.yellow
        case .critical: return Color.red
        }
    }

    private struct TileMetrics {
        let mark: CGFloat
        let countdown: CGFloat
        let percentage: CGFloat
        let gap: CGFloat
        let horizontalPadding: CGFloat

        func scaled(by scale: CGFloat) -> TileMetrics {
            TileMetrics(
                mark: mark * scale,
                countdown: countdown * scale,
                percentage: percentage * scale,
                gap: gap * scale,
                horizontalPadding: horizontalPadding * scale
            )
        }
    }

    private struct ContainerMetrics {
        let separatorWidth: CGFloat = 0.5
        let separatorInset: CGFloat
        let tileSize: CGSize

        init(size: CGSize, accountCount: Int) {
            let count = max(accountCount, 1)
            let separatorTotal = separatorWidth * CGFloat(max(count - 1, 0))
            let tileWidth = max((size.width - separatorTotal) / CGFloat(count), 0)
            tileSize = CGSize(width: tileWidth, height: max(size.height, 0))
            separatorInset = min(max(size.height * 0.0625, 2), 4)
        }
    }
}

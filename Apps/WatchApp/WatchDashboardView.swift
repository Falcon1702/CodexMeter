import SwiftUI
import UsageCore
import UserNotifications
import WatchUI

struct WatchDashboardView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: WatchDashboardModel

    var body: some View {
        Group {
            if let snapshot = model.snapshot, !snapshot.accounts.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            UsageColumnsView(
                                accounts: snapshot.accounts,
                                now: context.date,
                                allowsSemanticColors: true
                            )
                            .frame(height: 64)
                        }

                        ForEach(snapshot.accounts) { account in
                            HStack {
                                Text(account.displayName)
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text("\(account.displayRemainingPercent)%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(color(for: account.severity))
                            }
                            .accessibilityElement(children: .combine)
                        }

                        Text("Stand \(snapshot.generatedAt, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        notificationControl
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Keine Daten", systemImage: "iphone.and.arrow.forward")
                } description: {
                    Text("Öffne die iPhone-App und aktualisiere die Codex-Limits.")
                }
            }
        }
        .navigationTitle("Codex")
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            model.refreshFromStore()
        }
    }

    @ViewBuilder
    private var notificationControl: some View {
        switch model.notificationStatus {
        case .notDetermined:
            Button {
                Task { await model.enableNotifications() }
            } label: {
                Label("Reset-Hinweise", systemImage: "bell.badge")
            }
            .buttonStyle(.bordered)
            .font(.caption2)
        case .denied:
            Label("Hinweise in Einstellungen aus", systemImage: "bell.slash")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .authorized, .provisional, .ephemeral:
            EmptyView()
        @unknown default:
            EmptyView()
        }

        if let error = model.notificationError {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func color(for severity: UsageSeverity) -> Color {
        switch severity {
        case .healthy: return Color.accentColor
        case .warning: return Color.yellow
        case .critical: return Color.red
        }
    }
}

import SwiftUI
import UsageCore
import UserNotifications
import WatchUI

struct CompanionDashboardView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var showingConnection = false
    @State private var showingAccounts = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    intro
                    accountSetupCard

                    if let snapshot = model.snapshot, !snapshot.accounts.isEmpty {
                        UsageStrip(accounts: snapshot.accounts, now: .now)
                        accountList(snapshot.accounts)
                    } else {
                        emptyState
                    }

                    statusCard
                    notificationCard
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Codex Usage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingAccounts = true
                        } label: {
                            Label("Accounts & Datenquelle", systemImage: "person.2.badge.gearshape")
                        }

                        Button {
                            showingConnection = true
                        } label: {
                            Label("Bridge konfigurieren", systemImage: "network")
                        }
                    } label: {
                        Label(model.dataSourceMode.displayName, systemImage: dataSourceSymbol)
                    }
                    .accessibilityLabel("Datenquelle: \(model.dataSourceMode.displayName)")
                }
            }
            .refreshable {
                await model.refresh()
            }
            .sheet(isPresented: $showingConnection) {
                ConnectionSettingsView()
                    .environmentObject(model)
            }
            .sheet(isPresented: $showingAccounts) {
                AccountSetupView()
                    .environmentObject(model)
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Deine Limits auf einen Blick")
                .font(.title2.weight(.bold))
            Text("Bis zu drei Accounts für Watch, Homescreen und Sperrbildschirm.")
                .foregroundStyle(.secondary)
            Label("Datenquelle: \(model.dataSourceMode.displayName)", systemImage: dataSourceSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "applewatch")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Noch keine Nutzungsdaten")
                .font(.headline)
            Text(emptyStateDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Account hinzufügen") {
                showingAccounts = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
    }

    private var accountSetupCard: some View {
        let signedIn = model.bridgeAccounts.filter { $0.status == .signedIn }.count
        return HStack(spacing: 13) {
            Image(systemName: signedIn > 0 ? "person.2.badge.gearshape.fill" : "person.crop.circle.badge.plus")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Codex-Accounts")
                    .font(.headline)
                Text(accountSetupDetail(signedIn: signedIn))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(signedIn == 0 ? "Hinzufügen" : "Verwalten") {
                showingAccounts = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private func accountSetupDetail(signedIn: Int) -> String {
        switch model.accountState {
        case .loading where model.bridgeAccounts.isEmpty:
            return "Account-Status wird geladen …"
        case let .failed(message) where model.bridgeAccounts.isEmpty:
            return message
        default:
            switch model.dataSourceMode {
            case .direct:
                return "Direkt · \(signedIn) von \(model.maxBridgeAccounts) Slots angemeldet"
            case .bridge:
                return "Bridge · \(signedIn) von \(model.maxBridgeAccounts) Accounts angemeldet"
            }
        }
    }

    private var emptyStateDetail: String {
        switch model.dataSourceMode {
        case .direct:
            "Melde unter „Accounts & Datenquelle“ mindestens einen Codex-Account direkt auf diesem iPhone an."
        case .bridge:
            "Verbinde zuerst die lokale Bridge und melde danach mindestens einen Codex-Account an."
        }
    }

    private func accountList(_ accounts: [UsageAccount]) -> some View {
        VStack(spacing: 0) {
            ForEach(accounts) { account in
                HStack(spacing: 12) {
                    UsageServiceMarkView(
                        brand: account.serviceBrand,
                        fallback: account.displayName
                    )
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(account.displayRemainingPercent)% verbleibend")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(color(for: account.remainingPercent))
                        Text("Reset in \(ResetCountdownFormatter.string(until: account.resetsAt, now: .now))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.stale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Daten veraltet")
                    }
                }
                .padding(.vertical, 13)
                if account.id != accounts.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            Button {
                Task { await model.refresh() }
            } label: {
                if model.state == .loading {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.state == .loading)
            .accessibilityLabel("Aktualisieren")
        }
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Reset-Hinweise", systemImage: "bell.badge")
                .font(.headline)
            if let message = model.lastResetMessage {
                Text(message)
                    .font(.subheadline)
            }
            if model.notificationStatus == .authorized || model.notificationStatus == .provisional {
                Text("Aktiv. Erkannte Resets werden auf dem iPhone gemeldet und zur Watch übertragen. Watch-Hinweise werden dort separat freigegeben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.notificationStatus == .denied {
                Text("In den iPhone-Einstellungen deaktiviert. Dort kannst du Reset-Hinweise wieder freigeben.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Benachrichtigungen aktivieren") {
                    Task { await model.enableNotifications() }
                }
                .buttonStyle(.borderedProminent)
                Text("Die Erkennung läuft beim Abruf neuer Daten; eine garantierte Echtzeitmeldung braucht später einen Push-Dienst.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .idle: "Bereit"
        case .loading: "Codex-Limits werden geladen"
        case .loaded: "Nutzungsdaten aktualisiert"
        case .failed: "Aktualisierung fehlgeschlagen"
        }
    }

    private var statusDetail: String {
        switch model.state {
        case .idle:
            "Zum Laden nach unten ziehen oder den Aktualisieren-Button verwenden."
        case .loading:
            switch model.dataSourceMode {
            case .direct:
                "OpenAI wird direkt vom iPhone abgefragt …"
            case .bridge:
                "Lokale Bridge wird abgefragt …"
            }
        case let .loaded(date):
            "Stand: \(date.formatted(date: .omitted, time: .shortened)) · \(model.dataSourceMode.displayName)"
        case let .failed(message):
            message
        }
    }

    private var dataSourceSymbol: String {
        switch model.dataSourceMode {
        case .direct: "iphone.and.arrow.forward"
        case .bridge: "network"
        }
    }

    private func color(for remaining: Double) -> Color {
        switch remaining {
        case ..<10: return Color.red
        case 10 ..< 30: return Color.yellow
        default: return Color.accentColor
        }
    }
}

private struct UsageStrip: View {
    let accounts: [UsageAccount]
    let now: Date

    var body: some View {
        UsageHomeWidgetView(
            accounts: accounts,
            now: now,
            style: .medium,
            allowsSemanticColors: true
        )
        .padding(12)
        .frame(height: 112)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

}

private struct ConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CompanionModel
    @State private var draftAddress = ""
    @State private var draftToken = ""
    @State private var initialized = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Lokale Bridge") {
                    TextField("http://Mac-IP:8787", text: $draftAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("Bearer-Token", text: $draftToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Section {
                    Text("Auf einem echten iPhone muss hier die lokale IP oder der .local-Name des Macs stehen. Die Bridge bleibt standardmäßig nur auf 127.0.0.1 und muss für LAN-Zugriff ausdrücklich mit Token freigegeben werden.")
                }
            }
            .navigationTitle("Verbindung")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        do {
                            try model.saveConnection(address: draftAddress, token: draftToken)
                            dismiss()
                            Task {
                                await model.loadAccounts()
                                await model.refresh()
                            }
                        } catch {
                            saveError = error.localizedDescription
                        }
                    }
                    .disabled(model.deviceLoginState.isPending)
                }
            }
            .onAppear {
                guard !initialized else { return }
                draftAddress = model.bridgeAddress
                draftToken = model.bridgeToken
                initialized = true
            }
        }
    }
}

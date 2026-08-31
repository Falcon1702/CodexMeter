import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UsageCore
import WatchUI

struct AccountSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var model: CompanionModel

    @State private var accountToLogout: BridgeAccount?
    @State private var copiedCode = false
    @State private var isConfirmingLoginCancellation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Datenquelle") {
                    Picker("Datenquelle", selection: dataSourceBinding) {
                        ForEach(CompanionModel.UsageDataSourceMode.allCases) { mode in
                            Text(mode.displayName)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(sourceSelectionDisabled)

                    sourceExplanation
                }

                loginSection

                Section("Accounts") {
                    accountRows
                }

                if let error = model.accountActionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.yellow)
                        Button("Hinweis schließen") {
                            model.clearAccountActionError()
                        }
                    }
                }

                Section {
                    Text(sourcePrivacyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Codex-Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .task {
                await model.loadAccounts()
            }
            .confirmationDialog(
                "Account abmelden?",
                isPresented: Binding(
                    get: { accountToLogout != nil },
                    set: { if !$0 { accountToLogout = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let account = accountToLogout {
                    Button("\(account.displayName) abmelden", role: .destructive) {
                        accountToLogout = nil
                        Task { await model.logout(account) }
                    }
                }
                Button("Abbrechen", role: .cancel) {
                    accountToLogout = nil
                }
            } message: {
                Text(logoutMessage)
            }
            .confirmationDialog(
                "Laufende Anmeldung abbrechen?",
                isPresented: $isConfirmingLoginCancellation,
                titleVisibility: .visible
            ) {
                Button("Anmeldung wirklich abbrechen", role: .destructive) {
                    Task { await model.cancelCurrentLogin() }
                }
                Button("Weiter anmelden", role: .cancel) {}
            } message: {
                Text("Der aktuelle OpenAI-Code wird dadurch ungültig. Ohne Bestätigung wartet CodexMeter weiter.")
            }
        }
    }

    @ViewBuilder
    private var sourceExplanation: some View {
        switch model.dataSourceMode {
        case .direct:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Direkt mit OpenAI")
                        .font(.headline)
                    Text("Das iPhone fragt OpenAI direkt nach deinen Codex-Nutzungsdaten. Jede Sitzung liegt getrennt pro Slot nur im iPhone-Schlüsselbund; die Watch erhält keine Tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone.and.arrow.forward")
                    .foregroundStyle(.tint)
            }

        case .bridge:
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Login über deine lokale Bridge")
                        .font(.headline)
                    Text("Die iPhone-App erhält nur einen kurzlebigen Code und den Anmeldestatus. ChatGPT-Tokens bleiben auf dem Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tint)
            }
        }
    }

    private var dataSourceBinding: Binding<CompanionModel.UsageDataSourceMode> {
        Binding(
            get: { model.dataSourceMode },
            set: { model.setDataSourceMode($0) }
        )
    }

    private var sourceSelectionDisabled: Bool {
        model.deviceLoginState.isPending || model.accountActionID != nil
    }

    private var sourcePrivacyText: String {
        switch model.dataSourceMode {
        case .direct:
            "Bis zu \(model.maxBridgeAccounts) getrennte Slots. Mit „A anzeigen als“, „B anzeigen als“ usw. ordnest du jedem Slot sein Logo zu. Die ChatGPT-Sitzung jedes Slots wird nur im iPhone-Schlüsselbund gespeichert. Die Watch erhält ausschließlich Nutzungs- und Reset-Daten – niemals Tokens."
        case .bridge:
            "Bis zu \(model.maxBridgeAccounts) getrennte Accounts. Mit „A anzeigen als“, „B anzeigen als“ usw. ordnest du jedem Slot sein Logo zu. Anzeigenamen und Account-Slots werden auf dem Mac festgelegt; Passwörter und ChatGPT-Sitzungen werden nicht auf das iPhone oder die Watch übertragen."
        }
    }

    private var logoutMessage: String {
        switch model.dataSourceMode {
        case .direct:
            "Die Sitzung dieses Slots wird aus dem iPhone-Schlüsselbund entfernt. Die Watch besitzt keine Tokens."
        case .bridge:
            "Die Bridge meldet diesen Codex-Account ab. Lokale Profildateien werden dabei nicht gelöscht."
        }
    }

    @ViewBuilder
    private var loginSection: some View {
        switch model.deviceLoginState {
        case .idle:
            EmptyView()

        case let .starting(accountID):
            Section("Anmeldung") {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Anmeldecode für \(displayName(for: accountID)) wird angefordert …")
                        .font(.subheadline)
                }
            }

        case let .awaiting(login):
            Section("Anmeldung für \(displayName(for: login.accountID))") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Öffne die offizielle OpenAI-Seite und gib dort diesen Code ein:")
                        .font(.subheadline)

                    HStack(spacing: 12) {
                        Text(login.userCode)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                            .accessibilityLabel("Anmeldecode \(login.userCode)")
                        Spacer()
                        Button {
                            UIPasteboard.general.setItems(
                                [[UTType.utf8PlainText.identifier: login.userCode]],
                                options: [
                                    .localOnly: true,
                                    .expirationDate: login.expirationDate ?? Date().addingTimeInterval(10 * 60),
                                ]
                            )
                            copiedCode = true
                        } label: {
                            Label(copiedCode ? "Kopiert" : "Kopieren", systemImage: copiedCode ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let url = login.verificationURL {
                        Button {
                            model.noteVerificationPageOpened()
                            openURL(url)
                        } label: {
                            Label("OpenAI-Anmeldeseite öffnen", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HStack(spacing: 9) {
                        ProgressView()
                        Text("Warte auf deine Bestätigung …")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if model.dataSourceMode == .direct {
                        Text("Beim Wechsel zu Safari läuft die Anmeldung weiter. Der Code verfällt erst automatisch.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                if model.dataSourceMode == .bridge {
                    Button("Anmeldung abbrechen", role: .destructive) {
                        isConfirmingLoginCancellation = true
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.accountActionID != nil)
                }
            }

        case let .succeeded(accountID):
            Section("Anmeldung") {
                Label("\(displayName(for: accountID)) ist angemeldet.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Schließen") { model.clearLoginResult() }
            }

        case let .failed(accountID, message):
            Section("Anmeldung fehlgeschlagen") {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.yellow)
                if let accountID,
                   let account = model.bridgeAccounts.first(where: { $0.id == accountID })
                {
                    Button("Erneut versuchen") {
                        model.clearLoginResult()
                        Task { await model.beginLogin(for: account) }
                    }
                }
                Button("Schließen") { model.clearLoginResult() }
            }

        case .cancelled:
            Section("Anmeldung") {
                Label("Anmeldung abgebrochen", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
                Button("Schließen") { model.clearLoginResult() }
            }
        }
    }

    @ViewBuilder
    private var accountRows: some View {
        if model.bridgeAccounts.isEmpty {
            switch model.accountState {
            case .idle, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Accounts werden geladen …")
                        .foregroundStyle(.secondary)
                }

            case let .failed(message):
                VStack(alignment: .leading, spacing: 10) {
                    Label(message, systemImage: "network.slash")
                        .font(.subheadline)
                        .foregroundStyle(.yellow)
                    Button("Erneut laden") {
                        Task { await model.loadAccounts() }
                    }
                }

            case .loaded:
                Text(
                    model.dataSourceMode == .direct
                        ? "Die direkten Account-Slots konnten nicht geladen werden."
                        : "Auf der Bridge sind noch keine Account-Slots konfiguriert."
                )
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(model.bridgeAccounts) { account in
                accountRow(account)
            }
        }
    }

    private func accountRow(_ account: BridgeAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol(for: account.status))
                    .font(.title3)
                    .foregroundStyle(statusColor(for: account.status))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.headline)
                    HStack(spacing: 5) {
                        Text(statusText(for: account))
                        if let plan = account.planType, !plan.isEmpty {
                            Text("·")
                            Text(plan)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if model.accountActionID == account.id {
                    ProgressView()
                } else {
                    accountAction(for: account)
                }
            }

            Menu {
                Picker(
                    "\(account.displayName) anzeigen als",
                    selection: serviceBrandBinding(for: account.id)
                ) {
                    Text("Buchstabe \(account.displayName)")
                        .tag(nil as UsageServiceBrand?)
                    ForEach(UsageServiceBrand.allCases, id: \.self) { brand in
                        Text(brand.displayName)
                        .tag(brand as UsageServiceBrand?)
                    }
                }
                .labelsHidden()
            } label: {
                HStack(spacing: 9) {
                    UsageServiceMarkView(
                        brand: model.serviceBrand(for: account.id),
                        fallback: account.displayName
                    )
                    .frame(width: 28, height: 28)

                    Text("\(account.displayName) anzeigen als")
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 8)

                    Text(serviceBrandSelectionName(for: account))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.leading, 40)
            .accessibilityLabel("\(account.displayName) anzeigen als")
            .accessibilityValue(serviceBrandSelectionName(for: account))
        }
        .padding(.vertical, 4)
    }

    private func serviceBrandBinding(for accountID: String) -> Binding<UsageServiceBrand?> {
        Binding(
            get: { model.serviceBrand(for: accountID) },
            set: { model.setServiceBrand($0, for: accountID) }
        )
    }

    private func serviceBrandSelectionName(for account: BridgeAccount) -> String {
        model.serviceBrand(for: account.id)?.displayName
            ?? "Buchstabe \(account.displayName)"
    }

    private var activeLogin: DeviceLoginStartResponse? {
        guard case let .awaiting(login) = model.deviceLoginState else { return nil }
        return login
    }

    @ViewBuilder
    private func accountAction(for account: BridgeAccount) -> some View {
        if let activeLogin {
            if activeLogin.accountID == account.id {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Läuft")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Anmeldung läuft")
            }
        } else {
            switch account.status {
            case .signedOut, .error:
                Button("Anmelden") {
                    copiedCode = false
                    Task { await model.beginLogin(for: account) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.deviceLoginState.isPending)

            case .pending:
                Button("Abbrechen", role: .destructive) {
                    Task { await model.cancelPendingLogin(for: account) }
                }
                .buttonStyle(.bordered)

            case .signedIn:
                Button("Abmelden", role: .destructive) {
                    accountToLogout = account
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func displayName(for accountID: String) -> String {
        model.bridgeAccounts.first(where: { $0.id == accountID })?.displayName ?? "Account"
    }

    private func statusText(for account: BridgeAccount) -> String {
        switch account.status {
        case .signedOut: "Nicht angemeldet"
        case .pending:
            model.dataSourceMode == .direct
                ? "Anmeldung läuft"
                : "Anmeldung läuft – abbrechen und neu starten"
        case .signedIn: "Angemeldet"
        case .error:
            model.dataSourceMode == .direct
                ? "Anmeldung prüfen"
                : "Status nicht verfügbar"
        }
    }

    private func statusSymbol(for status: BridgeAccountStatus) -> String {
        switch status {
        case .signedOut: "person.crop.circle.badge.plus"
        case .pending: "clock.badge"
        case .signedIn: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for status: BridgeAccountStatus) -> Color {
        switch status {
        case .signedOut: .secondary
        case .pending: .orange
        case .signedIn: .green
        case .error: .yellow
        }
    }
}

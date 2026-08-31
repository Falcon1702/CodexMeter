import Combine
import Foundation
import OSLog
import UsageCore
import UserNotifications

@MainActor
final class CompanionModel: ObservableObject {
    static let shared = CompanionModel()

    enum UsageDataSourceMode: String, CaseIterable, Identifiable, Sendable {
        case direct
        case bridge

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .direct: "Direkt"
            case .bridge: "Bridge"
            }
        }
    }

    enum ConnectionSettingsError: LocalizedError {
        case loginInProgress

        var errorDescription: String? {
            switch self {
            case .loginInProgress:
                "Während einer laufenden Account-Anmeldung kann die Bridge-Verbindung nicht geändert werden."
            }
        }
    }

    private struct BridgeConnection: Sendable {
        let address: String
        let token: String
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    enum AccountLoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum DeviceLoginState: Equatable {
        case idle
        case starting(accountID: String)
        case awaiting(DeviceLoginStartResponse)
        case succeeded(accountID: String)
        case failed(accountID: String?, message: String)
        case cancelled

        var isPending: Bool {
            switch self {
            case .starting, .awaiting:
                true
            case .idle, .succeeded, .failed, .cancelled:
                false
            }
        }
    }

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var bridgeAccounts: [BridgeAccount] = []
    @Published private(set) var maxBridgeAccounts = 3
    @Published private(set) var accountState: AccountLoadState = .idle
    @Published private(set) var deviceLoginState: DeviceLoginState = .idle
    @Published private(set) var accountActionID: String?
    @Published private(set) var accountActionError: String?
    @Published private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastResetMessage: String?
    @Published private(set) var bridgeAddress: String
    @Published private(set) var bridgeToken: String
    @Published private(set) var accountBrandRevision = 0
    @Published private(set) var dataSourceMode: UsageDataSourceMode

    private let bridgeClient = BridgeClient()
    private let directClient: CodexDirectClient
    private let directProfiles: [CodexDirectAccountProfile]
    private let sync = WatchSyncCoordinator.shared
    private let notifications = ResetNotificationCoordinator.shared
    private let resetOutbox = ResetEventOutboxStore.shared
    private let loginLogger = Logger(
        subsystem: "com.example.codexmeter",
        category: "codex-login"
    )
    private var accountBrandStore: AccountBrandStore
    private var started = false
    private var pollingTask: Task<Void, Never>?
    private var loginPollingTask: Task<Void, Never>?
    private var loginPollingGeneration = 0
    private var activeLoginConnection: BridgeConnection?
    private var activeDirectLogin: CodexDirectDeviceLoginSession?
    private var directReauthenticationRequired = Set<String>()
    private var accountLoadInProgress = false
    private var accountLoadRequested = false
    private var connectionGeneration = 0
    private var refreshInProgress = false
    private var refreshRequested = false
    private var snapshotMutationGeneration = 0

    private static let dataSourceModeKey = "usageDataSourceMode"
    private static let snapshotDataSourceModeKey = "usageSnapshotDataSourceMode"

    init() {
        let accountBrandStore = AccountBrandStore()
        let defaults = UserDefaults.standard
        let selectedDataSource = defaults.string(forKey: Self.dataSourceModeKey)
            .flatMap(UsageDataSourceMode.init(rawValue:))
            ?? .direct
        let cachedDataSource = defaults.string(forKey: Self.snapshotDataSourceModeKey)
            .flatMap(UsageDataSourceMode.init(rawValue:))
        let directProfiles = zip(
            ["account-a", "account-b", "account-c"],
            ["A", "B", "C"]
        ).compactMap { id, name in
            try? CodexDirectAccountProfile(id: id, displayName: name)
        }

        self.accountBrandStore = accountBrandStore
        self.directProfiles = directProfiles
        directClient = CodexDirectClient(
            credentialStore: CodexDirectKeychainCredentialStore()
        )
        dataSourceMode = selectedDataSource
        bridgeAddress = defaults.string(forKey: "bridgeAddress")
            ?? "http://127.0.0.1:8787"
        bridgeToken = BridgeSecretStore.load()
        snapshot = cachedDataSource == selectedDataSource
            ? PhoneSnapshotStore.load().map {
                Self.applyingBrandSelections(
                    from: accountBrandStore,
                    to: $0.normalized(maxAccounts: 3)
                )
            }
            : nil
    }

    deinit {
        pollingTask?.cancel()
        loginPollingTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        sync.activate()
        if let snapshot {
            sync.send(snapshot, priority: false)
        }
        Task { [weak self] in
            guard let self else { return }
            self.notificationStatus = await self.notifications.authorizationStatus()
            do {
                try await self.notifications.retryPending()
            } catch {
                self.state = .failed("Gespeicherte Reset-Hinweise konnten nicht geladen werden.")
            }
        }
        pollingTask = Task { [weak self] in
            await self?.loadAccounts()
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(UsageRefreshPolicy.foregroundRefreshInterval)
                )
                guard !Task.isCancelled else { return }
                await self?.loadAccounts()
                await self?.refresh()
            }
        }
    }

    func saveConnection(address: String, token: String) throws {
        guard !deviceLoginState.isPending else {
            throw ConnectionSettingsError.loginInProgress
        }
        let connectionChanged = address != bridgeAddress || token != bridgeToken
        let clearedSnapshot = UsageSnapshot(
            schemaVersion: snapshot?.schemaVersion ?? 1,
            generatedAt: .now,
            accounts: []
        )
        if connectionChanged, dataSourceMode == .bridge {
            try saveSnapshotToCache(clearedSnapshot, source: .bridge)
        }
        try BridgeSecretStore.save(token)
        UserDefaults.standard.set(address, forKey: "bridgeAddress")
        bridgeAddress = address
        bridgeToken = token
        if connectionChanged, dataSourceMode == .bridge {
            connectionGeneration &+= 1
            invalidateInFlightSnapshot()
            bridgeAccounts = []
            maxBridgeAccounts = 3
            accountState = .idle
            snapshot = clearedSnapshot
            state = .idle
            sync.send(clearedSnapshot, priority: true)
        }
    }

    func setDataSourceMode(_ mode: UsageDataSourceMode) {
        guard mode != dataSourceMode else { return }
        guard !deviceLoginState.isPending else {
            accountActionError = "Während einer laufenden Anmeldung kann die Datenquelle nicht gewechselt werden."
            return
        }
        guard accountActionID == nil else {
            accountActionError = "Bitte warte, bis die Account-Aktion abgeschlossen ist."
            return
        }

        let clearedSnapshot = UsageSnapshot(
            schemaVersion: snapshot?.schemaVersion ?? 1,
            generatedAt: .now,
            accounts: []
        )
        do {
            try saveSnapshotToCache(clearedSnapshot, source: mode)
        } catch {
            accountActionError = "Die Datenquelle konnte nicht sicher gewechselt werden."
            return
        }

        invalidateLoginPolling()
        activeLoginConnection = nil
        activeDirectLogin = nil
        connectionGeneration &+= 1
        invalidateInFlightSnapshot()
        dataSourceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.dataSourceModeKey)
        bridgeAccounts = []
        maxBridgeAccounts = 3
        accountState = .idle
        deviceLoginState = .idle
        snapshot = clearedSnapshot
        state = .idle
        lastResetMessage = nil
        accountActionError = nil
        sync.send(clearedSnapshot, priority: true)

        Task { [weak self] in
            await self?.loadAccounts()
            await self?.refresh()
        }
    }

    func loadAccounts() async {
        if accountLoadInProgress {
            accountLoadRequested = true
            return
        }

        accountLoadInProgress = true
        defer { accountLoadInProgress = false }

        repeat {
            accountLoadRequested = false
            let generation = connectionGeneration
            let source = dataSourceMode
            accountState = .loading
            do {
                let response: BridgeAccountsResponse
                switch source {
                case .direct:
                    response = try await fetchDirectAccounts()
                case .bridge:
                    let connection = currentConnection
                    response = try await bridgeClient.fetchAccounts(
                        address: connection.address,
                        token: connection.token
                    )
                }
                guard generation == connectionGeneration,
                      source == dataSourceMode
                else { continue }
                bridgeAccounts = response.accounts
                maxBridgeAccounts = response.maxAccounts
                accountState = .loaded
            } catch {
                guard generation == connectionGeneration else { continue }
                accountState = .failed(error.localizedDescription)
            }
        } while accountLoadRequested
    }

    func beginLogin(for account: BridgeAccount) async {
        guard !deviceLoginState.isPending else { return }
        invalidateLoginPolling()
        invalidateInFlightSnapshot()
        accountActionError = nil
        let source = dataSourceMode
        recordLoginEvent("starting", source: source)
        deviceLoginState = .starting(accountID: account.id)
        let generation = connectionGeneration
        do {
            switch source {
            case .direct:
                guard let profile = directProfiles.first(where: { $0.id == account.id }) else {
                    throw CodexDirectClientError.invalidProfile
                }
                let session = try await directClient.startDeviceLogin(for: profile)
                guard generation == connectionGeneration,
                      dataSourceMode == .direct
                else { return }
                let login = directLoginPresentation(for: session)
                activeLoginConnection = nil
                activeDirectLogin = session
                recordLoginEvent("awaiting", source: .direct)
                deviceLoginState = .awaiting(login)
                await loadAccounts()
                startDirectPolling(session, presentation: login)

            case .bridge:
                let connection = currentConnection
                let login = try await bridgeClient.startDeviceLogin(
                    accountID: account.id,
                    address: connection.address,
                    token: connection.token
                )
                guard generation == connectionGeneration,
                      dataSourceMode == .bridge,
                      login.accountID == account.id
                else {
                    throw BridgeClientError.invalidResponse
                }
                activeDirectLogin = nil
                activeLoginConnection = connection
                recordLoginEvent("awaiting", source: .bridge)
                deviceLoginState = .awaiting(login)
                await loadAccounts()
                startBridgePolling(login, connection: connection)
            }
        } catch {
            activeLoginConnection = nil
            activeDirectLogin = nil
            recordLoginEvent("start-failed", source: source)
            deviceLoginState = .failed(
                accountID: account.id,
                message: error.localizedDescription
            )
        }
    }

    func cancelCurrentLogin() async {
        guard case let .awaiting(login) = deviceLoginState else { return }

        if dataSourceMode == .direct {
            // Direct device codes expire server-side. Keeping this path inert
            // makes a Safari/list lifecycle event incapable of cancelling login.
            recordLoginEvent("cancel-blocked", source: .direct)
            return
        }

        invalidateLoginPolling()
        let connection = activeLoginConnection ?? currentConnection
        do {
            let response = try await bridgeClient.cancelDeviceLogin(
                loginID: login.loginID,
                address: connection.address,
                token: connection.token
            )
            guard response.accountID == login.accountID,
                  response.loginID == login.loginID
            else {
                throw BridgeClientError.invalidResponse
            }
            switch response.status {
            case .cancelled:
                recordLoginEvent("cancel-confirmed", source: .bridge)
                deviceLoginState = .cancelled
            case .succeeded:
                invalidateInFlightSnapshot()
                recordLoginEvent("succeeded", source: .bridge)
                deviceLoginState = .succeeded(accountID: login.accountID)
                await refresh()
            case .failed:
                recordLoginEvent("cancel-failed", source: .bridge)
                deviceLoginState = .failed(
                    accountID: login.accountID,
                    message: "Die Anmeldung wurde nicht abgeschlossen. Bitte versuche es erneut."
                )
            case .pending:
                throw BridgeClientError.invalidResponse
            }
            activeLoginConnection = nil
            await loadAccounts()
        } catch {
            activeLoginConnection = nil
            recordLoginEvent("cancel-request-failed", source: .bridge)
            deviceLoginState = .failed(
                accountID: login.accountID,
                message: error.localizedDescription
            )
        }
    }

    func cancelPendingLogin(for account: BridgeAccount) async {
        guard let loginID = account.loginID else {
            accountActionError = "Diese Anmeldung kann nicht fortgesetzt werden. Bitte starte sie neu."
            return
        }
        let targetedActiveLogin: Bool
        if case let .awaiting(activeLogin) = deviceLoginState {
            targetedActiveLogin = activeLogin.accountID == account.id
                && activeLogin.loginID == loginID
        } else {
            targetedActiveLogin = false
        }
        accountActionID = account.id
        accountActionError = nil
        defer { accountActionID = nil }

        if dataSourceMode == .direct {
            recordLoginEvent("pending-cancel-blocked", source: .direct)
            accountActionError = targetedActiveLogin
                ? "Die direkte Anmeldung läuft weiter; der Code verfällt automatisch."
                : "Diese Anmeldung ist nicht mehr aktiv. Bitte starte sie neu."
            await loadAccounts()
            return
        }

        do {
            let response = try await bridgeClient.cancelDeviceLogin(
                loginID: loginID,
                address: bridgeAddress,
                token: bridgeToken
            )
            guard response.accountID == account.id,
                  response.loginID == loginID
            else {
                throw BridgeClientError.invalidResponse
            }
            let stillTargetsActiveLogin: Bool
            if targetedActiveLogin,
               case let .awaiting(activeLogin) = deviceLoginState
            {
                stillTargetsActiveLogin = activeLogin.accountID == account.id
                    && activeLogin.loginID == loginID
            } else {
                stillTargetsActiveLogin = false
            }
            switch response.status {
            case .cancelled:
                if stillTargetsActiveLogin {
                    invalidateLoginPolling()
                    activeLoginConnection = nil
                    recordLoginEvent("pending-cancel-confirmed", source: .bridge)
                    deviceLoginState = .cancelled
                }
            case .succeeded:
                invalidateInFlightSnapshot()
                if stillTargetsActiveLogin {
                    invalidateLoginPolling()
                    activeLoginConnection = nil
                    deviceLoginState = .succeeded(accountID: account.id)
                }
                await refresh()
            case .failed:
                if stillTargetsActiveLogin {
                    invalidateLoginPolling()
                    activeLoginConnection = nil
                    deviceLoginState = .failed(
                        accountID: account.id,
                        message: "Die Anmeldung wurde nicht abgeschlossen. Bitte versuche es erneut."
                    )
                } else {
                    accountActionError = "Die Anmeldung für \(account.displayName) wurde nicht abgeschlossen."
                }
            case .pending:
                throw BridgeClientError.invalidResponse
            }
            await loadAccounts()
        } catch {
            accountActionError = error.localizedDescription
        }
    }

    func logout(_ account: BridgeAccount) async {
        guard accountActionID == nil else { return }
        if dataSourceMode == .direct,
           case let .awaiting(login) = deviceLoginState,
           login.accountID == account.id
        {
            recordLoginEvent("logout-blocked", source: .direct)
            accountActionError = "Während der direkten Anmeldung kann dieser Slot nicht abgemeldet werden."
            return
        }
        accountActionID = account.id
        accountActionError = nil
        defer { accountActionID = nil }
        do {
            switch dataSourceMode {
            case .direct:
                try await directClient.signOut(profileID: account.id)
                directReauthenticationRequired.remove(account.id)
            case .bridge:
                let response = try await bridgeClient.logoutAccount(
                    accountID: account.id,
                    address: bridgeAddress,
                    token: bridgeToken
                )
                guard response.accountID == account.id,
                      response.status == .signedOut
                else {
                    throw BridgeClientError.invalidResponse
                }
            }
            invalidateInFlightSnapshot()
            let cacheWasSaved = removeAccountFromLocalSnapshot(account.id)
            if case let .awaiting(login) = deviceLoginState,
               login.accountID == account.id
            {
                invalidateLoginPolling()
                activeLoginConnection = nil
                activeDirectLogin = nil
                recordLoginEvent("logout-cancelled-login", source: dataSourceMode)
                deviceLoginState = .cancelled
            }
            await loadAccounts()
            if bridgeAccounts.contains(where: { $0.status == .signedIn }) {
                await refresh()
            }
            if !cacheWasSaved {
                accountActionError = "Der Account wurde abgemeldet, aber der lokale iPhone-Cache konnte nicht gespeichert werden. Die Watch wurde trotzdem sofort aktualisiert."
            }
        } catch {
            accountActionError = error.localizedDescription
        }
    }

    func clearLoginResult() {
        guard !deviceLoginState.isPending else { return }
        activeLoginConnection = nil
        activeDirectLogin = nil
        deviceLoginState = .idle
    }

    func clearAccountActionError() {
        accountActionError = nil
    }

    func noteVerificationPageOpened() {
        recordLoginEvent("verification-opened", source: dataSourceMode)
    }

    func serviceBrand(for accountID: String) -> UsageServiceBrand? {
        accountBrandStore.serviceBrand(for: accountID)
    }

    func setServiceBrand(
        _ serviceBrand: UsageServiceBrand?,
        for accountID: String
    ) {
        accountActionError = nil
        do {
            try accountBrandStore.setServiceBrand(serviceBrand, for: accountID)
            accountBrandRevision &+= 1
        } catch {
            accountActionError = "Die Logo-Auswahl konnte nicht gespeichert werden."
            return
        }

        guard let current = snapshot else { return }
        let branded = applyingBrandSelections(to: current)
        let cacheWasSaved = (try? saveSnapshotToCache(branded, source: dataSourceMode)) != nil
        snapshot = branded
        sync.send(branded, priority: true)
        if !cacheWasSaved {
            accountActionError = "Die Logo-Auswahl wurde gespeichert, aber der lokale iPhone-Cache konnte nicht aktualisiert werden. Die Watch wurde trotzdem sofort aktualisiert."
        }
    }

    func resumeAfterForeground() {
        Task { [weak self] in
            await self?.loadAccounts()
            await self?.refresh()
        }
        // iOS suspends and resumes the existing login task when Safari takes over.
        // Replacing it here creates a race around a one-time authorization grant.
    }

    func prepareForBackgroundRefresh() {
        sync.activate()
    }

    private func recordLoginEvent(
        _ event: String,
        source: UsageDataSourceMode
    ) {
        loginLogger.notice(
            "Login event: \(event, privacy: .public); source: \(source.rawValue, privacy: .public)"
        )
    }

    @discardableResult
    func refresh() async -> Bool {
        if refreshInProgress {
            refreshRequested = true
            return false
        }

        refreshInProgress = true
        defer { refreshInProgress = false }

        var succeeded = false
        repeat {
            refreshRequested = false
            succeeded = await performRefresh(generation: snapshotMutationGeneration)
        } while refreshRequested
        return succeeded
    }

    func refreshForBackgroundTask() async -> Bool {
        if refreshInProgress {
            refreshRequested = true
            while refreshInProgress, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return false }
            if case .loaded = state {
                return true
            }
            return false
        }
        return await refresh()
    }

    private func performRefresh(generation: Int) async -> Bool {
        state = .loading
        do {
            let previous = snapshot
            let source = dataSourceMode
            let fetched: UsageSnapshot
            switch source {
            case .direct:
                fetched = try await fetchDirectSnapshot(previous: previous)
            case .bridge:
                let connection = currentConnection
                fetched = try await bridgeClient.fetchSnapshot(
                    address: connection.address,
                    token: connection.token
                )
            }
            guard generation == snapshotMutationGeneration,
                  source == dataSourceMode
            else { return false }
            let current = applyingBrandSelections(to: fetched)

            let resetEvents = previous.map {
                ResetEventDetector().detect(previous: $0, current: current)
            } ?? []
            let watchPresentationChanged = !hasSameWatchPresentation(
                previous,
                current
            )

            // Notification delivery becomes durable before the cached snapshot
            // moves the reset detector's baseline forward. Recheck the generation
            // after the await so a concurrent logout cannot resurrect stale data.
            try await notifications.enqueueAndDeliver(resetEvents)
            guard generation == snapshotMutationGeneration else { return false }
            let refreshedBranding = applyingBrandSelections(to: fetched)
            try resetOutbox.append(resetEvents)
            try saveSnapshotToCache(refreshedBranding, source: source)
            snapshot = refreshedBranding
            state = .loaded(refreshedBranding.generatedAt)
            sync.send(
                refreshedBranding,
                resetEvents: resetEvents,
                priority: watchPresentationChanged || !resetEvents.isEmpty
            )

            if let event = resetEvents.last {
                let message = event.kind == .resetCreditIncrease
                    ? "Ein neuer Reset-Credit ist verfügbar."
                    : "Das Nutzungsfenster ist wieder frei."
                lastResetMessage = "\(event.displayName): \(message)"
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == snapshotMutationGeneration else { return false }
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private func hasSameWatchPresentation(
        _ older: UsageSnapshot?,
        _ newer: UsageSnapshot
    ) -> Bool {
        guard let older else { return newer.accounts.isEmpty }
        guard older.accounts.count == newer.accounts.count else { return false }

        return zip(older.accounts, newer.accounts).allSatisfy { old, new in
            old.id == new.id
                && old.displayName == new.displayName
                && old.displayRemainingPercent == new.displayRemainingPercent
                && old.resetsAt == new.resetsAt
                && old.stale == new.stale
                && old.serviceBrand == new.serviceBrand
        }
    }

    func enableNotifications() async {
        do {
            _ = try await notifications.requestAuthorization()
            notificationStatus = await notifications.authorizationStatus()
        } catch {
            state = .failed("Benachrichtigungen konnten nicht aktiviert werden: \(error.localizedDescription)")
        }
    }

    private var currentConnection: BridgeConnection {
        BridgeConnection(address: bridgeAddress, token: bridgeToken)
    }

    private func fetchDirectAccounts() async throws -> BridgeAccountsResponse {
        var accounts: [BridgeAccount] = []
        accounts.reserveCapacity(directProfiles.count)

        let pendingLogin: DeviceLoginStartResponse? = if case let .awaiting(login) = deviceLoginState {
            login
        } else {
            nil
        }

        for profile in directProfiles {
            if pendingLogin?.accountID == profile.id {
                accounts.append(
                    BridgeAccount(
                        id: profile.id,
                        displayName: profile.displayName,
                        status: .pending,
                        authMode: "chatgpt",
                        planType: nil,
                        loginID: pendingLogin?.loginID
                    )
                )
                continue
            }

            if directReauthenticationRequired.contains(profile.id) {
                accounts.append(
                    BridgeAccount(
                        id: profile.id,
                        displayName: profile.displayName,
                        status: .error,
                        authMode: "chatgpt",
                        planType: nil,
                        loginID: nil
                    )
                )
                continue
            }

            do {
                let session = try await directClient.accountSession(for: profile)
                accounts.append(
                    BridgeAccount(
                        id: profile.id,
                        displayName: profile.displayName,
                        status: session == nil ? .signedOut : .signedIn,
                        authMode: session == nil ? nil : "chatgpt",
                        planType: session?.planType,
                        loginID: nil
                    )
                )
            } catch {
                accounts.append(
                    BridgeAccount(
                        id: profile.id,
                        displayName: profile.displayName,
                        status: .error,
                        authMode: "chatgpt",
                        planType: nil,
                        loginID: nil
                    )
                )
            }
        }

        return BridgeAccountsResponse(maxAccounts: 3, accounts: accounts)
    }

    private func fetchDirectSnapshot(previous: UsageSnapshot?) async throws -> UsageSnapshot {
        var accounts: [UsageAccount] = []
        accounts.reserveCapacity(directProfiles.count)
        var firstError: Error?

        for profile in directProfiles {
            if directReauthenticationRequired.contains(profile.id) {
                let error = CodexDirectClientError.reauthenticationRequired
                firstError = firstError ?? error
                appendStaleDirectAccount(profileID: profile.id, from: previous, to: &accounts)
                continue
            }

            do {
                guard try await directClient.accountSession(for: profile) != nil else {
                    directReauthenticationRequired.remove(profile.id)
                    continue
                }

                do {
                    let usage = try await directClient.fetchUsage(for: profile)
                    directReauthenticationRequired.remove(profile.id)
                    accounts.append(
                        UsageAccount(
                            id: profile.id,
                            displayName: profile.displayName,
                            remainingPercent: usage.remainingPercent,
                            usedPercent: usage.usedPercent,
                            resetsAt: usage.resetsAt,
                            windowDurationMinutes: usage.windowDurationMinutes,
                            windowLabel: usage.windowLabel,
                            resetCredits: usage.resetCredits,
                            stale: false
                        )
                    )
                } catch {
                    firstError = firstError ?? error
                    if case CodexDirectClientError.reauthenticationRequired = error {
                        directReauthenticationRequired.insert(profile.id)
                    } else if case CodexDirectClientError.accountChanged = error {
                        directReauthenticationRequired.insert(profile.id)
                    }
                    appendStaleDirectAccount(profileID: profile.id, from: previous, to: &accounts)
                }
            } catch {
                firstError = firstError ?? error
                appendStaleDirectAccount(profileID: profile.id, from: previous, to: &accounts)
            }
        }

        if accounts.isEmpty, let firstError {
            throw firstError
        }

        return UsageSnapshot(
            schemaVersion: previous?.schemaVersion ?? 1,
            generatedAt: .now,
            accounts: accounts
        ).normalized(maxAccounts: 3)
    }

    private func appendStaleDirectAccount(
        profileID: String,
        from previous: UsageSnapshot?,
        to accounts: inout [UsageAccount]
    ) {
        guard var stale = previous?.accounts.first(where: { $0.id == profileID }) else {
            return
        }
        stale.stale = true
        accounts.append(stale)
    }

    private func saveSnapshotToCache(
        _ snapshot: UsageSnapshot,
        source: UsageDataSourceMode
    ) throws {
        try PhoneSnapshotStore.save(snapshot)
        UserDefaults.standard.set(source.rawValue, forKey: Self.snapshotDataSourceModeKey)
    }

    private func directLoginPresentation(
        for session: CodexDirectDeviceLoginSession
    ) -> DeviceLoginStartResponse {
        DeviceLoginStartResponse(
            accountID: session.profile.id,
            loginID: "direct-\(session.profile.id)-\(UUID().uuidString)",
            verificationURLString: session.verificationURL.absoluteString,
            userCode: session.userCode,
            status: .pending,
            expiresAt: ISO8601DateFormatter().string(from: session.expiresAt),
            intervalSeconds: Int(min(ceil(session.pollInterval), 15 * 60))
        )
    }

    private func applyingBrandSelections(to snapshot: UsageSnapshot) -> UsageSnapshot {
        Self.applyingBrandSelections(from: accountBrandStore, to: snapshot)
    }

    private static func applyingBrandSelections(
        from store: AccountBrandStore,
        to snapshot: UsageSnapshot
    ) -> UsageSnapshot {
        var branded = snapshot
        branded.accounts = snapshot.accounts.map { source in
            var account = source
            account.serviceBrand = store.serviceBrand(for: account.id)
            return account
        }
        return branded
    }

    private func invalidateInFlightSnapshot() {
        snapshotMutationGeneration &+= 1
    }

    private func startBridgePolling(
        _ login: DeviceLoginStartResponse,
        connection: BridgeConnection
    ) {
        loginPollingTask?.cancel()
        loginPollingGeneration &+= 1
        let generation = loginPollingGeneration
        loginPollingTask = Task { [weak self] in
            await self?.pollDeviceLogin(
                login,
                connection: connection,
                generation: generation
            )
        }
    }

    private func startDirectPolling(
        _ session: CodexDirectDeviceLoginSession,
        presentation login: DeviceLoginStartResponse
    ) {
        loginPollingTask?.cancel()
        loginPollingGeneration &+= 1
        let generation = loginPollingGeneration
        let sourceGeneration = connectionGeneration
        loginPollingTask = Task { [weak self] in
            await self?.pollDirectDeviceLogin(
                session,
                presentation: login,
                generation: generation,
                sourceGeneration: sourceGeneration
            )
        }
    }

    private func invalidateLoginPolling() {
        loginPollingGeneration &+= 1
        loginPollingTask?.cancel()
        loginPollingTask = nil
    }

    private func isCurrentLoginPoll(
        _ login: DeviceLoginStartResponse,
        generation: Int
    ) -> Bool {
        guard !Task.isCancelled,
              generation == loginPollingGeneration,
              case let .awaiting(activeLogin) = deviceLoginState
        else {
            return false
        }
        return activeLogin.accountID == login.accountID
            && activeLogin.loginID == login.loginID
    }

    private func removeAccountFromLocalSnapshot(_ accountID: String) -> Bool {
        let current = snapshot ?? PhoneSnapshotStore.load()
        let reduced = UsageSnapshot(
            schemaVersion: current?.schemaVersion ?? 1,
            generatedAt: .now,
            accounts: current?.accounts.filter { $0.id != accountID } ?? []
        )
        let saved = (try? saveSnapshotToCache(reduced, source: dataSourceMode)) != nil
        snapshot = reduced
        state = .loaded(reduced.generatedAt)
        // An empty snapshot is intentional here: it clears an account that may
        // otherwise remain visible as stale on an offline Watch.
        sync.send(reduced, priority: true)
        return saved
    }

    private func pollDirectDeviceLogin(
        _ session: CodexDirectDeviceLoginSession,
        presentation login: DeviceLoginStartResponse,
        generation: Int,
        sourceGeneration: Int
    ) async {
        var failureCount = 0

        while !Task.isCancelled, Date.now < session.expiresAt {
            do {
                if failureCount > 0 {
                    try await Task.sleep(for: .seconds(min(2 + failureCount, 5)))
                }
                guard dataSourceMode == .direct,
                      sourceGeneration == connectionGeneration,
                      isCurrentLoginPoll(login, generation: generation)
                else { return }

                _ = try await directClient.completeDeviceLogin(session)
                guard dataSourceMode == .direct,
                      sourceGeneration == connectionGeneration,
                      isCurrentLoginPoll(login, generation: generation)
                else { return }

                directReauthenticationRequired.remove(login.accountID)
                invalidateInFlightSnapshot()
                activeDirectLogin = nil
                recordLoginEvent("succeeded", source: .direct)
                deviceLoginState = .succeeded(accountID: login.accountID)
                await loadAccounts()
                await refresh()
                return
            } catch is CancellationError {
                return
            } catch where isRetryableLoginPollingError(error) {
                guard dataSourceMode == .direct,
                      sourceGeneration == connectionGeneration,
                      isCurrentLoginPoll(login, generation: generation)
                else { return }
                let retryEvent = (error as? URLError)?.code == .cancelled
                    ? "transport-cancel-retry"
                    : "transport-retry"
                recordLoginEvent(retryEvent, source: .direct)
                failureCount += 1
            } catch {
                guard dataSourceMode == .direct,
                      sourceGeneration == connectionGeneration,
                      isCurrentLoginPoll(login, generation: generation)
                else { return }
                activeDirectLogin = nil
                recordLoginEvent("poll-failed", source: .direct)
                deviceLoginState = .failed(
                    accountID: login.accountID,
                    message: error.localizedDescription
                )
                await loadAccounts()
                return
            }
        }

        guard dataSourceMode == .direct,
              sourceGeneration == connectionGeneration,
              isCurrentLoginPoll(login, generation: generation)
        else { return }
        activeDirectLogin = nil
        recordLoginEvent("expired", source: .direct)
        deviceLoginState = .failed(
            accountID: login.accountID,
            message: "Der Anmeldecode ist abgelaufen. Bitte starte die Anmeldung neu."
        )
        await loadAccounts()
    }

    private func pollDeviceLogin(
        _ login: DeviceLoginStartResponse,
        connection: BridgeConnection,
        generation: Int
    ) async {
        let clock = ContinuousClock()
        let reportedSecondsUntilExpiry = login.expirationDate?.timeIntervalSinceNow ?? 10 * 60
        let secondsUntilExpiry = min(max(reportedSecondsUntilExpiry, 1), 10 * 60)
        let deadline = clock.now + .seconds(secondsUntilExpiry)
        let normalDelay = Duration.seconds(min(max(login.intervalSeconds ?? 2, 1), 5))
        var failureCount = 0

        while !Task.isCancelled, clock.now < deadline {
            do {
                try await Task.sleep(for: failureCount == 0
                    ? normalDelay
                    : .seconds(min(2 + failureCount, 5)))
                guard isCurrentLoginPoll(login, generation: generation) else { return }

                let response = try await bridgeClient.fetchDeviceLoginStatus(
                    loginID: login.loginID,
                    address: connection.address,
                    token: connection.token
                )
                guard isCurrentLoginPoll(login, generation: generation) else { return }
                guard response.accountID == login.accountID,
                      response.loginID == login.loginID
                else {
                    throw BridgeClientError.invalidResponse
                }
                failureCount = 0

                switch response.status {
                case .pending:
                    continue
                case .succeeded:
                    invalidateInFlightSnapshot()
                    activeLoginConnection = nil
                    recordLoginEvent("succeeded", source: .bridge)
                    deviceLoginState = .succeeded(accountID: login.accountID)
                    await loadAccounts()
                    await refresh()
                    return
                case .failed:
                    activeLoginConnection = nil
                    recordLoginEvent("poll-failed", source: .bridge)
                    deviceLoginState = .failed(
                        accountID: login.accountID,
                        message: "Die Anmeldung wurde nicht abgeschlossen. Bitte versuche es erneut."
                    )
                    await loadAccounts()
                    return
                case .cancelled:
                    activeLoginConnection = nil
                    recordLoginEvent("server-cancelled", source: .bridge)
                    deviceLoginState = .cancelled
                    await loadAccounts()
                    return
                }
            } catch is CancellationError {
                return
            } catch let BridgeClientError.server(_, code) where code == "login_not_found" {
                guard isCurrentLoginPoll(login, generation: generation) else { return }
                activeLoginConnection = nil
                deviceLoginState = .failed(
                    accountID: login.accountID,
                    message: "Die Anmeldung wurde unterbrochen oder ist abgelaufen. Bitte starte sie neu."
                )
                await loadAccounts()
                return
            } catch where isRetryableLoginPollingError(error) {
                guard isCurrentLoginPoll(login, generation: generation) else { return }
                failureCount += 1
                // A short LAN interruption must not abandon a still-active
                // login ceremony on the Mac. Retry with capped backoff until
                // the server-provided expiry deadline.
            } catch {
                guard isCurrentLoginPoll(login, generation: generation) else { return }
                activeLoginConnection = nil
                deviceLoginState = .failed(
                    accountID: login.accountID,
                    message: error.localizedDescription
                )
                await loadAccounts()
                return
            }
        }

        guard isCurrentLoginPoll(login, generation: generation) else { return }
        activeLoginConnection = nil
        deviceLoginState = .failed(
            accountID: login.accountID,
            message: "Der Anmeldecode ist abgelaufen. Bitte starte die Anmeldung neu."
        )
        await loadAccounts()
    }

    private func isRetryableLoginPollingError(_ error: Error) -> Bool {
        if LoginTransportRetryPolicy.isRetryable(error) {
            return true
        }
        if case let BridgeClientError.server(status, _) = error {
            return status == 408
                || status == 425
                || status == 429
                || (500 ... 599).contains(status)
        }
        if case let CodexDirectClientError.serverRejected(status) = error {
            return status == 408
                || status == 425
                || status == 429
                || (500 ... 599).contains(status)
        }
        return false
    }
}

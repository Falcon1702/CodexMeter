import Foundation

struct CodexDirectEndpoints: Equatable, Sendable {
    let deviceCodeURL: URL
    let deviceTokenURL: URL
    let verificationURL: URL
    let oauthTokenURL: URL
    let oauthRedirectURL: URL
    let usageURL: URL

    static let production = CodexDirectEndpoints(
        deviceCodeURL: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!,
        deviceTokenURL: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!,
        verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
        oauthTokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        oauthRedirectURL: URL(string: "https://auth.openai.com/deviceauth/callback")!,
        usageURL: URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    )
}

actor CodexDirectClient {
    typealias DateProvider = @Sendable () -> Date
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let loginLifetime: TimeInterval = 15 * 60
    private static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let fallbackRefreshAge: TimeInterval = 8 * 24 * 60 * 60
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    private let session: URLSession
    private let parser: any CodexDirectResponseParsing
    private let credentialStore: any CodexDirectCredentialStoring
    private let endpoints: CodexDirectEndpoints
    private let now: DateProvider
    private let sleep: Sleep
    private let redirectDelegate = CodexDirectNoRedirectDelegate()
    private var refreshTasks: [String: Task<CodexDirectCredentials, Error>] = [:]
    private var profileEpochs: [String: UInt64] = [:]
    private var cloudflareCookies: [CloudflareCookieKey: CloudflareCookie] = [:]

    init(
        credentialStore: any CodexDirectCredentialStoring,
        session: URLSession = CodexDirectClient.makeEphemeralSession(),
        parser: any CodexDirectResponseParsing = CodexDirectResponseParser(),
        endpoints: CodexDirectEndpoints = .production,
        now: @escaping DateProvider = Date.init,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.credentialStore = credentialStore
        self.session = Self.isSafeSessionConfiguration(session.configuration)
            ? session
            : Self.makeEphemeralSession()
        self.parser = parser
        self.endpoints = endpoints
        self.now = now
        self.sleep = sleep
    }

    static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func isSafeSessionConfiguration(
        _ configuration: URLSessionConfiguration
    ) -> Bool {
        !configuration.httpShouldSetCookies
            && configuration.httpCookieStorage == nil
            && (configuration.httpAdditionalHeaders?.isEmpty ?? true)
    }

    func startDeviceLogin(for profile: CodexDirectAccountProfile) async throws
        -> CodexDirectDeviceLoginSession
    {
        let epoch = advanceProfileEpoch(profile.id)
        refreshTasks.removeValue(forKey: profile.id)?.cancel()
        var request = jsonRequest(url: endpoints.deviceCodeURL, method: "POST")
        request.httpBody = try JSONEncoder().encode(DeviceCodeRequest(clientID: Self.oauthClientID))
        let (data, response) = try await execute(request)
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodexDirectClientError.serverRejected(status: response.statusCode)
        }
        let payload = try parser.parseDeviceCode(data)
        return CodexDirectDeviceLoginSession(
            profile: profile,
            verificationURL: endpoints.verificationURL,
            userCode: payload.userCode,
            pollInterval: payload.interval,
            expiresAt: now().addingTimeInterval(Self.loginLifetime),
            deviceAuthorizationID: payload.deviceAuthorizationID,
            credentialEpoch: epoch
        )
    }

    /// Polls until the device ceremony completes, exchanges the grant and stores the
    /// resulting refreshable credentials in Keychain. Cancelling the surrounding Task
    /// stops polling immediately; the server-side code expires on its own.
    func completeDeviceLogin(_ login: CodexDirectDeviceLoginSession) async throws
        -> CodexDirectAccountSession
    {
        while now() < login.expiresAt {
            try Task.checkCancellation()
            try requireCurrentProfileEpoch(
                login.credentialEpoch,
                profileID: login.profile.id
            )
            switch try await pollDeviceLogin(login) {
            case .pending:
                let remaining = login.expiresAt.timeIntervalSince(now())
                guard remaining > 0 else {
                    throw CodexDirectClientError.loginExpired
                }
                try await sleep(min(login.pollInterval, remaining))
            case let .authorized(grant):
                return try await exchangeAndStore(
                    grant,
                    profile: login.profile,
                    epoch: login.credentialEpoch
                )
            }
        }
        throw CodexDirectClientError.loginExpired
    }

    func accountSession(for profile: CodexDirectAccountProfile) async throws
        -> CodexDirectAccountSession?
    {
        guard let credentials = try await credentialStore.load(profileID: profile.id) else {
            return nil
        }
        let accessTokenExpiresAt = (try? parser.parseJWTClaims(credentials.accessToken))?.expiresAt
        return CodexDirectAccountSession(
            profile: profile,
            planType: credentials.planType,
            authenticatedAt: credentials.lastRefresh,
            accessTokenExpiresAt: accessTokenExpiresAt
        )
    }

    func cancelDeviceLogin(profileID: String) throws {
        guard CodexDirectValidation.isProfileID(profileID) else {
            throw CodexDirectClientError.invalidProfile
        }
        _ = advanceProfileEpoch(profileID)
        refreshTasks.removeValue(forKey: profileID)?.cancel()
    }

    func fetchUsage(for profile: CodexDirectAccountProfile) async throws -> CodexDirectUsage {
        let epoch = currentProfileEpoch(profile.id)
        guard let stored = try await credentialStore.load(profileID: profile.id) else {
            throw CodexDirectClientError.notAuthenticated
        }
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)

        var credentials = try await refreshIfNeeded(
            stored,
            profileID: profile.id,
            epoch: epoch
        )
        var (data, response) = try await requestUsage(credentials)
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        if response.statusCode == 401 {
            credentials = try await refresh(
                credentials,
                profileID: profile.id,
                epoch: epoch
            )
            (data, response) = try await requestUsage(credentials)
            try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw CodexDirectClientError.reauthenticationRequired
            }
            throw CodexDirectClientError.serverRejected(status: response.statusCode)
        }

        let parsed = try parser.parseUsage(data)
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        return CodexDirectUsage(
            profileID: profile.id,
            planType: parsed.planType ?? credentials.planType,
            remainingPercent: parsed.remainingPercent,
            usedPercent: parsed.usedPercent,
            resetsAt: parsed.resetsAt,
            windowDurationMinutes: parsed.windowDurationMinutes,
            resetCredits: parsed.resetCredits
        )
    }

    func signOut(profileID: String) async throws {
        guard CodexDirectValidation.isProfileID(profileID) else {
            throw CodexDirectClientError.invalidProfile
        }
        _ = advanceProfileEpoch(profileID)
        refreshTasks.removeValue(forKey: profileID)?.cancel()
        try await credentialStore.delete(profileID: profileID)
    }

    private enum LoginPollResult {
        case pending
        case authorized(CodexDirectAuthorizationGrant)
    }

    private func pollDeviceLogin(_ login: CodexDirectDeviceLoginSession) async throws
        -> LoginPollResult
    {
        var request = jsonRequest(url: endpoints.deviceTokenURL, method: "POST")
        request.httpBody = try JSONEncoder().encode(
            DeviceTokenRequest(
                deviceAuthorizationID: login.deviceAuthorizationID,
                userCode: login.userCode
            )
        )
        let (data, response) = try await execute(request)
        if response.statusCode == 403 || response.statusCode == 404 {
            return .pending
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodexDirectClientError.serverRejected(status: response.statusCode)
        }
        return .authorized(try parser.parseAuthorizationGrant(data))
    }

    private func exchangeAndStore(
        _ grant: CodexDirectAuthorizationGrant,
        profile: CodexDirectAccountProfile,
        epoch: UInt64
    ) async throws -> CodexDirectAccountSession {
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        var request = URLRequest(url: endpoints.oauthTokenURL)
        request.httpMethod = "POST"
        applyCommonHeaders(to: &request)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formEncoded([
            ("grant_type", "authorization_code"),
            ("code", grant.authorizationCode),
            ("redirect_uri", endpoints.oauthRedirectURL.absoluteString),
            ("client_id", Self.oauthClientID),
            ("code_verifier", grant.codeVerifier),
        ])

        let (data, response) = try await execute(request)
        try requireCurrentProfileEpoch(epoch, profileID: profile.id)
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodexDirectClientError.serverRejected(status: response.statusCode)
        }
        let tokens = try parser.parseTokenExchange(data)
        let idClaims = try parser.parseJWTClaims(tokens.idToken)
        guard let accountID = idClaims.chatGPTAccountID else {
            throw CodexDirectClientError.invalidResponse
        }

        let refreshedAt = now()
        let credentials = CodexDirectCredentials(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            chatGPTAccountID: accountID,
            planType: idClaims.planType,
            isFedRamp: idClaims.isFedRamp,
            lastRefresh: refreshedAt
        )
        try await saveCredentialsIfCurrent(
            credentials,
            profileID: profile.id,
            epoch: epoch
        )
        let accessTokenExpiresAt = (try? parser.parseJWTClaims(tokens.accessToken))?.expiresAt
        return CodexDirectAccountSession(
            profile: profile,
            planType: credentials.planType,
            authenticatedAt: refreshedAt,
            accessTokenExpiresAt: accessTokenExpiresAt
        )
    }

    private func refreshIfNeeded(
        _ credentials: CodexDirectCredentials,
        profileID: String,
        epoch: UInt64
    ) async throws -> CodexDirectCredentials {
        guard shouldRefresh(credentials) else { return credentials }
        do {
            return try await refresh(
                credentials,
                profileID: profileID,
                epoch: epoch
            )
        } catch CodexDirectClientError.reauthenticationRequired {
            throw CodexDirectClientError.reauthenticationRequired
        } catch CodexDirectClientError.accountChanged {
            throw CodexDirectClientError.accountChanged
        } catch CodexDirectClientError.operationSuperseded {
            throw CodexDirectClientError.operationSuperseded
        } catch let error as CodexDirectCredentialStoreError {
            throw error
        } catch {
            // Match Codex's behavior: a failed proactive refresh may still leave a
            // currently valid access token, so let the authenticated request decide.
            try Task.checkCancellation()
            return credentials
        }
    }

    private func shouldRefresh(_ credentials: CodexDirectCredentials) -> Bool {
        if let claims = try? parser.parseJWTClaims(credentials.accessToken),
           let expiration = claims.expiresAt {
            return expiration <= now().addingTimeInterval(Self.accessTokenRefreshWindow)
        }
        return credentials.lastRefresh <= now().addingTimeInterval(-Self.fallbackRefreshAge)
    }

    private func refresh(
        _ credentials: CodexDirectCredentials,
        profileID: String,
        epoch: UInt64
    ) async throws -> CodexDirectCredentials {
        try requireCurrentProfileEpoch(epoch, profileID: profileID)
        if let task = refreshTasks[profileID] {
            let refreshed = try await task.value
            try requireCurrentProfileEpoch(epoch, profileID: profileID)
            return refreshed
        }
        if let current = try await credentialStore.load(profileID: profileID) {
            try requireCurrentProfileEpoch(epoch, profileID: profileID)
            guard current.chatGPTAccountID == credentials.chatGPTAccountID else {
                throw CodexDirectClientError.accountChanged
            }
            if current.accessToken != credentials.accessToken
                || current.refreshToken != credentials.refreshToken
            {
                return current
            }
        }

        let task = Task {
            try await self.performRefresh(
                credentials,
                profileID: profileID,
                epoch: epoch
            )
        }
        refreshTasks[profileID] = task
        do {
            let refreshed = try await task.value
            if currentProfileEpoch(profileID) == epoch {
                refreshTasks[profileID] = nil
            }
            return refreshed
        } catch {
            if currentProfileEpoch(profileID) == epoch {
                refreshTasks[profileID] = nil
            }
            throw error
        }
    }

    private func performRefresh(
        _ credentials: CodexDirectCredentials,
        profileID: String,
        epoch: UInt64
    ) async throws -> CodexDirectCredentials {
        try requireCurrentProfileEpoch(epoch, profileID: profileID)
        var request = jsonRequest(url: endpoints.oauthTokenURL, method: "POST")
        request.httpBody = try JSONEncoder().encode(
            RefreshRequest(
                clientID: Self.oauthClientID,
                grantType: "refresh_token",
                refreshToken: credentials.refreshToken
            )
        )
        let (data, response) = try await execute(request)
        try requireCurrentProfileEpoch(epoch, profileID: profileID)
        try Task.checkCancellation()
        guard (200 ..< 300).contains(response.statusCode) else {
            let code = parser.parseOAuthErrorCode(data)?.lowercased()
            if response.statusCode == 401
                || code == "refresh_token_expired"
                || code == "refresh_token_reused"
                || code == "refresh_token_invalidated"
            {
                throw CodexDirectClientError.reauthenticationRequired
            }
            throw CodexDirectClientError.serverRejected(status: response.statusCode)
        }

        let rotation = try parser.parseTokenRefresh(data)
        let idToken = rotation.idToken ?? credentials.idToken
        let accessToken = rotation.accessToken ?? credentials.accessToken
        let refreshToken = rotation.refreshToken ?? credentials.refreshToken
        let claims = try parser.parseJWTClaims(idToken)
        guard let accountID = claims.chatGPTAccountID else {
            throw CodexDirectClientError.invalidResponse
        }
        guard accountID == credentials.chatGPTAccountID else {
            throw CodexDirectClientError.accountChanged
        }

        let updated = CodexDirectCredentials(
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            chatGPTAccountID: accountID,
            planType: claims.planType ?? credentials.planType,
            isFedRamp: claims.isFedRamp,
            lastRefresh: now()
        )
        try await saveCredentialsIfCurrent(
            updated,
            profileID: profileID,
            epoch: epoch
        )
        return updated
    }

    private func currentProfileEpoch(_ profileID: String) -> UInt64 {
        profileEpochs[profileID] ?? 0
    }

    @discardableResult
    private func advanceProfileEpoch(_ profileID: String) -> UInt64 {
        let next = currentProfileEpoch(profileID) &+ 1
        profileEpochs[profileID] = next
        return next
    }

    private func requireCurrentProfileEpoch(
        _ epoch: UInt64,
        profileID: String
    ) throws {
        guard currentProfileEpoch(profileID) == epoch else {
            throw CodexDirectClientError.operationSuperseded
        }
    }

    private func saveCredentialsIfCurrent(
        _ credentials: CodexDirectCredentials,
        profileID: String,
        epoch: UInt64
    ) async throws {
        try Task.checkCancellation()
        try requireCurrentProfileEpoch(epoch, profileID: profileID)
        try await credentialStore.save(credentials, profileID: profileID)

        guard currentProfileEpoch(profileID) == epoch else {
            // The Keychain write was already queued when a newer login/logout
            // advanced this slot. Remove only the exact stale blob; never erase
            // credentials committed by the newer operation.
            if try await credentialStore.load(profileID: profileID) == credentials {
                try await credentialStore.delete(profileID: profileID)
            }
            throw CodexDirectClientError.operationSuperseded
        }
        if Task.isCancelled {
            if try await credentialStore.load(profileID: profileID) == credentials {
                try await credentialStore.delete(profileID: profileID)
            }
            throw CancellationError()
        }
    }

    private func requestUsage(_ credentials: CodexDirectCredentials) async throws
        -> (Data, HTTPURLResponse)
    {
        guard CodexDirectValidation.isHeaderValue(credentials.accessToken, maximumLength: 64 * 1_024),
              CodexDirectValidation.isHeaderValue(credentials.chatGPTAccountID, maximumLength: 512)
        else {
            throw CodexDirectClientError.invalidResponse
        }
        var request = URLRequest(url: endpoints.usageURL)
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        if credentials.isFedRamp {
            request.setValue("true", forHTTPHeaderField: "X-OpenAI-Fedramp")
        }
        applyCloudflareCookies(to: &request)
        return try await execute(request)
    }

    private func jsonRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyCommonHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func applyCommonHeaders(to request: inout URLRequest) {
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexMeter/1.0 CodexDirect/0.148", forHTTPHeaderField: "User-Agent")
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = request.url, isAllowedRequestURL(requestURL) else {
            throw CodexDirectClientError.invalidResponse
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        guard let http = response as? HTTPURLResponse else {
            throw CodexDirectClientError.invalidResponse
        }
        guard http.url == request.url, !(300 ..< 400).contains(http.statusCode) else {
            throw CodexDirectClientError.redirectRejected
        }
        if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
            throw CodexDirectClientError.responseTooLarge
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw CodexDirectClientError.responseTooLarge
            }
            data.append(byte)
        }
        captureCloudflareCookies(from: http)
        return (data, http)
    }

    private func isAllowedRequestURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.port == nil || components.port == 443,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host?.lowercased()
        else {
            return false
        }

        switch (host, components.path) {
        case ("auth.openai.com", "/api/accounts/deviceauth/usercode"),
             ("auth.openai.com", "/api/accounts/deviceauth/token"),
             ("auth.openai.com", "/oauth/token"),
             ("chatgpt.com", "/backend-api/wham/usage"):
            return true
        default:
            return false
        }
    }

    private struct CloudflareCookieKey: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    private struct CloudflareCookie {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresAt: Date?

        func applies(to url: URL, at date: Date) -> Bool {
            guard let host = url.host?.lowercased(), url.scheme?.lowercased() == "https" else {
                return false
            }
            let normalizedDomain = domain.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: ".")
            )
            let domainMatches = host == normalizedDomain || host.hasSuffix(".\(normalizedDomain)")
            let requestPath = url.path.isEmpty ? "/" : url.path
            let cookiePath = path.isEmpty ? "/" : path
            let pathMatches = requestPath == cookiePath
                || (requestPath.hasPrefix(cookiePath)
                    && (cookiePath.hasSuffix("/")
                        || requestPath.dropFirst(cookiePath.count).first == "/"))
            let isCurrent = expiresAt.map { $0 > date } ?? true
            return domainMatches && pathMatches && isCurrent
        }
    }

    private func captureCloudflareCookies(from response: HTTPURLResponse) {
        guard let url = response.url, isAllowedChatGPTHost(url.host),
              url.scheme?.lowercased() == "https"
        else {
            return
        }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        let currentDate = now()
        for cookie in received where isAllowedCloudflareCookieName(cookie.name) && cookie.isSecure {
            let key = CloudflareCookieKey(
                name: cookie.name,
                domain: cookie.domain.lowercased(),
                path: cookie.path
            )
            if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= currentDate }) == true {
                cloudflareCookies[key] = nil
            } else if CodexDirectValidation.isHeaderValue(cookie.value, maximumLength: 4_096) {
                cloudflareCookies[key] = CloudflareCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expiresAt: cookie.expiresDate
                )
            }
        }
    }

    private func applyCloudflareCookies(to request: inout URLRequest) {
        guard let url = request.url, isAllowedChatGPTHost(url.host) else { return }
        let currentDate = now()
        cloudflareCookies = cloudflareCookies.filter {
            $0.value.expiresAt.map { $0 > currentDate } ?? true
        }
        let value = cloudflareCookies.values
            .filter { $0.applies(to: url, at: currentDate) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: "Cookie")
        }
    }

    private func isAllowedChatGPTHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "chatgpt.com"
            || host == "chat.openai.com"
            || host == "chatgpt-staging.com"
            || host.hasSuffix(".chatgpt.com")
            || host.hasSuffix(".chatgpt-staging.com")
    }

    private func isAllowedCloudflareCookieName(_ name: String) -> Bool {
        [
            "__cf_bm",
            "__cflb",
            "__cfruid",
            "__cfseq",
            "__cfwaitingroom",
            "_cfuvid",
            "cf_clearance",
            "cf_ob_info",
            "cf_use_ob",
        ].contains(name) || name.hasPrefix("cf_chl_")
    }

    private func formEncoded(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let value = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(value.utf8)
    }
}

private struct DeviceCodeRequest: Encodable {
    let clientID: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct DeviceTokenRequest: Encodable {
    let deviceAuthorizationID: String
    let userCode: String

    enum CodingKeys: String, CodingKey {
        case deviceAuthorizationID = "device_auth_id"
        case userCode = "user_code"
    }
}

private struct RefreshRequest: Encodable {
    let clientID: String
    let grantType: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case grantType = "grant_type"
        case refreshToken = "refresh_token"
    }
}

private final class CodexDirectNoRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

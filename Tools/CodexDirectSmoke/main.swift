import Darwin
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SmokeFailure.failed(message) }
}

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jwt(accountID: String, plan: String, expiresAt: Date) throws -> String {
    let payload = try jsonData([
        "exp": expiresAt.timeIntervalSince1970,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountID,
            "chatgpt_plan_type": plan,
        ],
    ])
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).signature"
}

private actor InMemoryCredentialStore: CodexDirectCredentialStoring {
    private var values: [String: CodexDirectCredentials] = [:]

    func load(profileID: String) async throws -> CodexDirectCredentials? {
        values[profileID]
    }

    func save(_ credentials: CodexDirectCredentials, profileID: String) async throws {
        values[profileID] = credentials
    }

    func delete(profileID: String) async throws {
        values[profileID] = nil
    }
}

private struct RecordedRequest {
    let request: URLRequest
    let body: Data?
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RecordedRequest] = []

    func append(_ request: URLRequest) {
        let recorded = RecordedRequest(request: request, body: Self.readBody(from: request))
        lock.lock()
        stored.append(recorded)
        lock.unlock()
    }

    func snapshot() -> [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var blocked = false

    func block() {
        lock.lock()
        blocked = true
        lock.unlock()
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func waitUntilBlocked() async throws {
        for _ in 0 ..< 500 {
            if isCurrentlyBlocked() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SmokeFailure.failed("Race-Test hat den blockierten Request nicht erreicht")
    }

    func release() {
        semaphore.signal()
    }

    private func isCurrentlyBlocked() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)
    nonisolated(unsafe) static var handler: Handler?

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: SmokeFailure.failed("Kein URL-Handler installiert"))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func response(
    for request: URLRequest,
    status: Int,
    headers: [String: String] = [:],
    body: Any = [:]
) throws -> (HTTPURLResponse, Data) {
    guard let url = request.url,
          let response = HTTPURLResponse(
              url: url,
              statusCode: status,
              httpVersion: "HTTP/1.1",
              headerFields: headers
          )
    else {
        throw SmokeFailure.failed("HTTP-Antwort konnte nicht gebaut werden")
    }
    return (response, try jsonData(body))
}

@main
private struct CodexDirectSmoke {
    static func main() async {
        do {
            try await run()
            print("CodexDirectSmoke: PASS")
        } catch {
            fputs("CodexDirectSmoke: FAIL – \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        try require(
            LoginTransportRetryPolicy.isRetryable(URLError(.cancelled)),
            "iOS-Transportabbruch beim Safari-Wechsel wird nicht wiederholt"
        )
        try require(
            LoginTransportRetryPolicy.isRetryable(URLError(.timedOut)),
            "Timeout wird nicht wiederholt"
        )
        try require(
            !LoginTransportRetryPolicy.isRetryable(URLError(.badURL)),
            "Nicht vorübergehender URL-Fehler wird wiederholt"
        )
        try require(
            !LoginTransportRetryPolicy.isRetryable(CancellationError()),
            "Logische Task-Cancellation wurde als Transportfehler eingestuft"
        )

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        do {
            _ = try CodexDirectResponseParser().parseDeviceCode(
                jsonData([
                    "device_auth_id": "device-auth-invalid",
                    "user_code": "ABCD-EFGH",
                    "interval": "1.5",
                ])
            )
            throw SmokeFailure.failed("Nicht-ganzzahliges Device-Polling-Intervall wurde akzeptiert")
        } catch CodexDirectClientError.invalidResponse {
            // Expected: Codex specifies whole seconds.
        }
        let accountAIDToken = try jwt(
            accountID: "chatgpt-account-a",
            plan: "plus",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let accountAAccessToken = try jwt(
            accountID: "chatgpt-account-a",
            plan: "plus",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let accountBIDToken = try jwt(
            accountID: "chatgpt-account-b",
            plan: "team",
            expiresAt: now.addingTimeInterval(3_600)
        )
        let recorder = RequestRecorder()
        let usageRaceGate = BlockingGate()

        StubURLProtocol.handler = { request in
            recorder.append(request)
            guard let url = request.url else {
                throw SmokeFailure.failed("Request ohne URL")
            }

            switch (url.host, url.path, request.httpMethod) {
            case ("auth.openai.com", "/api/accounts/deviceauth/usercode", "POST"):
                return try response(
                    for: request,
                    status: 200,
                    body: [
                        "device_auth_id": "device-auth-a",
                        "user_code": "ABCD-EFGH",
                        "interval": "1",
                    ]
                )

            case ("auth.openai.com", "/api/accounts/deviceauth/token", "POST"):
                return try response(
                    for: request,
                    status: 200,
                    body: [
                        "authorization_code": "authorization-a",
                        "code_challenge": "challenge-a",
                        "code_verifier": "verifier-a",
                    ]
                )

            case ("auth.openai.com", "/oauth/token", "POST"):
                let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.hasPrefix("application/x-www-form-urlencoded") {
                    return try response(
                        for: request,
                        status: 200,
                        body: [
                            "id_token": accountAIDToken,
                            "access_token": accountAAccessToken,
                            "refresh_token": "refresh-a",
                        ]
                    )
                }
                return try response(
                    for: request,
                    status: 200,
                    body: [
                        "id_token": accountBIDToken,
                        "access_token": "access-b-rotated",
                        "refresh_token": "refresh-b-rotated",
                    ]
                )

            case ("chatgpt.com", "/backend-api/wham/usage", "GET"):
                let accountID = request.value(forHTTPHeaderField: "ChatGPT-Account-ID")
                let authorization = request.value(forHTTPHeaderField: "Authorization")
                if accountID == "chatgpt-account-c" {
                    usageRaceGate.block()
                }
                if accountID == "chatgpt-account-b", authorization == "Bearer access-b-old" {
                    return try response(for: request, status: 401)
                }
                return try response(
                    for: request,
                    status: 200,
                    headers: ["Set-Cookie": "__cf_bm=opaque-test-cookie; Path=/; Secure; HttpOnly"],
                    body: [
                        "plan_type": accountID == "chatgpt-account-b" ? "team" : "plus",
                        "rate_limit": [
                            "primary_window": [
                                "used_percent": 32.4,
                                "limit_window_seconds": 18_000,
                                "reset_at": 2_000_010_000,
                            ],
                            "secondary_window": [
                                "used_percent": 68.6,
                                "limit_window_seconds": 604_800,
                                "reset_at": 2_000_020_000,
                            ],
                        ],
                        "additional_rate_limits": [
                            [
                                "rate_limit": [
                                    "primary_window": [
                                        "used_percent": 90.2,
                                        "limit_window_seconds": 3_600,
                                        "reset_at": 2_000_015_000,
                                    ],
                                ],
                            ],
                        ],
                        "rate_limit_reset_credits": ["available_count": 2],
                    ]
                )

            default:
                throw SmokeFailure.failed("Unerwarteter Request: \(request.httpMethod ?? "?") \(url.absoluteString)")
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let store = InMemoryCredentialStore()
        let client = CodexDirectClient(
            credentialStore: store,
            session: session,
            now: { now },
            sleep: { _ in }
        )
        let profileA = try CodexDirectAccountProfile(id: "account-a", displayName: "A")

        let login = try await client.startDeviceLogin(for: profileA)
        try require(login.userCode == "ABCD-EFGH", "Device-Code wurde falsch geparst")
        try require(
            login.verificationURL.absoluteString == "https://auth.openai.com/codex/device",
            "Falsche Verifikations-URL"
        )
        let signedIn = try await client.completeDeviceLogin(login)
        try require(signedIn.profile.id == profileA.id, "Login wurde dem falschen Slot zugeordnet")

        let usageA = try await client.fetchUsage(for: profileA)
        try require(usageA.usedPercent == 90, "Das knappste Usage-Fenster wurde nicht gewählt")
        try require(usageA.remainingPercent == 10, "Verbleibende Prozentzahl ist falsch")
        try require(usageA.windowDurationMinutes == 60, "Fensterdauer ist falsch")
        try require(usageA.resetCredits == 2, "Reset-Credits wurden nicht übernommen")

        let profileB = try CodexDirectAccountProfile(id: "account-b", displayName: "B")
        try await store.save(
            CodexDirectCredentials(
                idToken: accountBIDToken,
                accessToken: "access-b-old",
                refreshToken: "refresh-b-old",
                chatGPTAccountID: "chatgpt-account-b",
                planType: "team",
                isFedRamp: false,
                lastRefresh: now
            ),
            profileID: profileB.id
        )
        let usageB = try await client.fetchUsage(for: profileB)
        try require(usageB.profileID == profileB.id, "Usage wurde dem falschen Profil zugeordnet")
        let rotatedB = try await store.load(profileID: profileB.id)
        try require(rotatedB?.refreshToken == "refresh-b-rotated", "Refresh-Token wurde nicht rotiert")
        try require(
            rotatedB?.chatGPTAccountID == "chatgpt-account-b",
            "Account-ID wurde beim Refresh vermischt"
        )

        let requests = recorder.snapshot()
        let deviceStart = try requireRequest(
            requests,
            path: "/api/accounts/deviceauth/usercode",
            occurrence: 0
        )
        let deviceStartBody = try decodeJSONObject(deviceStart.body)
        try require(
            deviceStartBody["client_id"] as? String == "app_EMoamEEZ73f0CkXaXp7hrann",
            "OAuth-Client-ID fehlt beim Device-Code"
        )
        try require(
            deviceStart.request.value(forHTTPHeaderField: "Cookie") == nil,
            "ChatGPT-Cookie ist an auth.openai.com geleakt"
        )

        let exchange = requests.first {
            $0.request.url?.path == "/oauth/token"
                && ($0.request.value(forHTTPHeaderField: "Content-Type") ?? "")
                    .hasPrefix("application/x-www-form-urlencoded")
        }
        let exchangeBody = exchange?.body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        try require(exchangeBody.contains("code_verifier=verifier-a"), "PKCE-Verifier fehlt")
        try require(
            exchangeBody.contains("redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback"),
            "OAuth-Redirect wurde falsch form-encodiert"
        )

        let bUsageRequests = requests.filter {
            $0.request.url?.path == "/backend-api/wham/usage"
                && $0.request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "chatgpt-account-b"
        }
        try require(bUsageRequests.count == 2, "401 wurde nicht exakt einmal wiederholt")
        try require(
            bUsageRequests.last?.request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-b-rotated",
            "Usage-Retry nutzt nicht den rotierten Access-Token"
        )

        let profileC = try CodexDirectAccountProfile(id: "account-c", displayName: "C")
        try await store.save(
            CodexDirectCredentials(
                idToken: try jwt(
                    accountID: "chatgpt-account-c",
                    plan: "plus",
                    expiresAt: now.addingTimeInterval(3_600)
                ),
                accessToken: "access-c-old",
                refreshToken: "refresh-c-old",
                chatGPTAccountID: "chatgpt-account-c",
                planType: "plus",
                isFedRamp: false,
                lastRefresh: now
            ),
            profileID: profileC.id
        )
        let supersededUsage = Task {
            try await client.fetchUsage(for: profileC)
        }
        try await usageRaceGate.waitUntilBlocked()
        let newerLogin = try await client.startDeviceLogin(for: profileC)
        usageRaceGate.release()
        do {
            _ = try await supersededUsage.value
            throw SmokeFailure.failed("Alte Usage-Antwort wurde nach neuerem Login veröffentlicht")
        } catch CodexDirectClientError.operationSuperseded {
            // Expected: the per-profile epoch rejects the old response.
        }
        try await client.cancelDeviceLogin(profileID: newerLogin.profile.id)

        let requestsBeforeRejectedEndpoint = recorder.snapshot().count
        let rejectedEndpointClient = CodexDirectClient(
            credentialStore: store,
            session: session,
            endpoints: CodexDirectEndpoints(
                deviceCodeURL: URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!,
                deviceTokenURL: URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!,
                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                oauthTokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
                oauthRedirectURL: URL(string: "https://auth.openai.com/deviceauth/callback")!,
                usageURL: URL(string: "http://example.invalid/steal")!
            ),
            now: { now }
        )
        do {
            _ = try await rejectedEndpointClient.fetchUsage(for: profileA)
            throw SmokeFailure.failed("Fremder oder unverschlüsselter Usage-Endpunkt wurde akzeptiert")
        } catch CodexDirectClientError.invalidResponse {
            // Expected: destination allowlist rejects before URLSession sees it.
        }
        try require(
            recorder.snapshot().count == requestsBeforeRejectedEndpoint,
            "Abgelehnter Endpunkt hat trotzdem einen Netzwerkrequest ausgelöst"
        )

        try await client.signOut(profileID: profileA.id)
        let signedOutA = try await store.load(profileID: profileA.id)
        let stillSignedInB = try await store.load(profileID: profileB.id)
        try require(signedOutA == nil, "Sign-out hat Slot A nicht gelöscht")
        try require(stillSignedInB != nil, "Sign-out von A hat Slot B gelöscht")
    }

    private static func requireRequest(
        _ requests: [RecordedRequest],
        path: String,
        occurrence: Int
    ) throws -> RecordedRequest {
        let matching = requests.filter { $0.request.url?.path == path }
        guard matching.indices.contains(occurrence) else {
            throw SmokeFailure.failed("Request \(path) fehlt")
        }
        return matching[occurrence]
    }

    private static func decodeJSONObject(_ data: Data?) throws -> [String: Any] {
        guard let data,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SmokeFailure.failed("JSON-Requestbody fehlt")
        }
        return object
    }
}

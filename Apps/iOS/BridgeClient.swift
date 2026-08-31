import Foundation
import UsageCore

enum BridgeClientError: LocalizedError {
    case invalidAddress
    case invalidIdentifier
    case insecureRemoteAddress
    case missingBearerToken
    case redirectRejected
    case invalidResponse
    case server(status: Int, code: String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Die Bridge-Adresse ist ungültig."
        case .invalidIdentifier:
            "Die Bridge hat eine ungültige Account- oder Login-ID geliefert."
        case .insecureRemoteAddress:
            "Für eine entfernte Bridge ist HTTPS nötig. HTTP ist nur im lokalen Netz erlaubt."
        case .missingBearerToken:
            "Für HTTP im lokalen Netz ist ein Bearer-Token erforderlich."
        case .redirectRejected:
            "Bridge-Weiterleitungen werden aus Sicherheitsgründen nicht akzeptiert."
        case .invalidResponse:
            "Die Bridge hat keine gültige HTTP-Antwort geliefert."
        case let .server(status, code):
            Self.serverMessage(status: status, code: code)
        }
    }

    private static func serverMessage(status: Int, code: String) -> String {
        switch code {
        case "bad_request":
            return "Die Bridge hat die Anfrage abgelehnt."
        case "account_not_found":
            return "Dieser Account ist in der Bridge nicht konfiguriert."
        case "login_not_found":
            return "Diese Anmeldung ist nicht mehr verfügbar. Bitte starte sie neu."
        case "already_signed_in":
            return "Dieser Account ist bereits angemeldet."
        case "login_in_progress":
            return "Für diesen Account läuft bereits eine Anmeldung."
        case "auth_unavailable":
            return "Der Codex-Login ist auf dem Mac gerade nicht verfügbar. Prüfe gegebenenfalls die Device-Code-Freigabe in ChatGPT Security oder den Workspace-Berechtigungen."
        case "unauthorized":
            return "Der Bridge-Token stimmt nicht. Bitte prüfe die Verbindungseinstellungen."
        case "snapshot_unavailable":
            return "Die Bridge konnte gerade keine Nutzungsdaten laden."
        case "not_found":
            return "Diese Bridge-Version unterstützt die angeforderte Funktion nicht."
        default:
            return "Bridge-Fehler \(status)."
        }
    }
}

enum BridgeAccountStatus: String, Codable, Sendable {
    case signedOut = "signed_out"
    case pending
    case signedIn = "signed_in"
    case error
}

struct BridgeAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let status: BridgeAccountStatus
    let authMode: String?
    let planType: String?
    let loginID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case status
        case authMode
        case planType
        case loginID = "loginId"
    }
}

struct BridgeAccountsResponse: Codable, Equatable, Sendable {
    let maxAccounts: Int
    let accounts: [BridgeAccount]
}

enum DeviceLoginStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case failed
    case cancelled
}

struct DeviceLoginStartResponse: Codable, Equatable, Sendable {
    let accountID: String
    let loginID: String
    let verificationURLString: String
    let userCode: String
    let status: DeviceLoginStatus
    let expiresAt: String?
    let intervalSeconds: Int?

    var verificationURL: URL? {
        guard verificationURLString == "https://auth.openai.com/codex/device",
              let url = URL(string: verificationURLString)
        else {
            return nil
        }
        return url
    }

    var expirationDate: Date? {
        guard let expiresAt else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: expiresAt) {
            return date
        }
        return ISO8601DateFormatter().date(from: expiresAt)
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case loginID = "loginId"
        case verificationURLString = "verificationUrl"
        case userCode
        case status
        case expiresAt
        case intervalSeconds
    }
}

struct DeviceLoginStatusResponse: Codable, Equatable, Sendable {
    let accountID: String
    let loginID: String
    let status: DeviceLoginStatus

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case loginID = "loginId"
        case status
    }
}

struct BridgeAccountStatusResponse: Codable, Equatable, Sendable {
    let accountID: String
    let status: BridgeAccountStatus

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case status
    }
}

private struct BridgeAccountRequest: Codable, Sendable {
    let accountID: String

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
    }
}

private struct BridgeErrorResponse: Decodable {
    let error: String
}

struct BridgeClient: Sendable {
    private let session: URLSession
    private let redirectDelegate = NoRedirectSessionDelegate()

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeEphemeralSession()
    }

    func fetchSnapshot(address: String, token: String) async throws -> UsageSnapshot {
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "snapshot"]
        )
        let snapshot = try UsageSnapshotCodec.decode(data)
        return snapshot.normalized(maxAccounts: 3)
    }

    func fetchAccounts(address: String, token: String) async throws -> BridgeAccountsResponse {
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "accounts"]
        )
        let response = try JSONDecoder().decode(BridgeAccountsResponse.self, from: data)
        guard (1 ... 3).contains(response.maxAccounts),
              response.accounts.count <= 3,
              Set(response.accounts.map(\.id)).count == response.accounts.count
        else {
            throw BridgeClientError.invalidResponse
        }
        for account in response.accounts {
            guard (try? validatedIdentifier(account.id, maximumLength: 32)) != nil,
                  (1 ... 12).contains(account.displayName.count)
            else {
                throw BridgeClientError.invalidResponse
            }
        }
        return BridgeAccountsResponse(
            maxAccounts: response.maxAccounts,
            accounts: response.accounts
        )
    }

    func startDeviceLogin(
        accountID: String,
        address: String,
        token: String
    ) async throws -> DeviceLoginStartResponse {
        let validatedAccountID = try validatedIdentifier(accountID, maximumLength: 32)
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "auth", "device", "start"],
            method: "POST",
            body: try JSONEncoder().encode(BridgeAccountRequest(accountID: validatedAccountID))
        )
        let response = try JSONDecoder().decode(DeviceLoginStartResponse.self, from: data)
        guard response.status == .pending,
              response.verificationURL != nil,
              (try? validatedIdentifier(response.accountID, maximumLength: 32)) != nil,
              (try? validatedIdentifier(response.loginID, maximumLength: 128)) != nil,
              (4 ... 64).contains(response.userCode.utf8.count),
              response.userCode.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45
              })
        else {
            throw BridgeClientError.invalidResponse
        }
        return response
    }

    func fetchDeviceLoginStatus(
        loginID: String,
        address: String,
        token: String
    ) async throws -> DeviceLoginStatusResponse {
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "auth", "device", try validatedIdentifier(loginID, maximumLength: 128)]
        )
        return try JSONDecoder().decode(DeviceLoginStatusResponse.self, from: data)
    }

    func cancelDeviceLogin(
        loginID: String,
        address: String,
        token: String
    ) async throws -> DeviceLoginStatusResponse {
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "auth", "device", try validatedIdentifier(loginID, maximumLength: 128)],
            method: "DELETE"
        )
        return try JSONDecoder().decode(DeviceLoginStatusResponse.self, from: data)
    }

    func logoutAccount(
        accountID: String,
        address: String,
        token: String
    ) async throws -> BridgeAccountStatusResponse {
        let data = try await request(
            address: address,
            token: token,
            pathComponents: ["v1", "accounts", try validatedIdentifier(accountID, maximumLength: 32)],
            method: "DELETE"
        )
        return try JSONDecoder().decode(BridgeAccountStatusResponse.self, from: data)
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    private func request(
        address: String,
        token: String,
        pathComponents: [String],
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = try endpointURL(
            from: address,
            pathComponents: pathComponents,
            hasBearerToken: !normalizedToken.isEmpty
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !normalizedToken.isEmpty {
            request.setValue("Bearer \(normalizedToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard http.url == endpoint, !(300 ..< 400).contains(http.statusCode) else {
            throw BridgeClientError.redirectRejected
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error)
                ?? "request_failed"
            throw BridgeClientError.server(status: http.statusCode, code: code)
        }
        return data
    }

    private func endpointURL(
        from address: String,
        pathComponents: [String],
        hasBearerToken: Bool
    ) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw BridgeClientError.invalidAddress
        }

        if scheme == "http", !Self.isLoopbackHost(host) {
            guard Self.isPrivateIPv4Address(host) || Self.isLocalHostname(host) else {
                throw BridgeClientError.insecureRemoteAddress
            }
            guard hasBearerToken else {
                throw BridgeClientError.missingBearerToken
            }
        }

        // URL fragments never reach the server and would make the strict
        // response-URL comparison fail even without a redirect.
        components.fragment = nil

        let cleanPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = cleanPath == "v1/snapshot" ? "" : cleanPath
        components.path = "/" + ([basePath].filter { !$0.isEmpty } + pathComponents)
            .joined(separator: "/")
        guard let url = components.url else {
            throw BridgeClientError.invalidAddress
        }
        return url
    }

    private func validatedIdentifier(_ value: String, maximumLength: Int) throws -> String {
        guard (1 ... maximumLength).contains(value.utf8.count),
              let first = value.utf8.first,
              (48 ... 57).contains(first)
                  || (65 ... 90).contains(first)
                  || (97 ... 122).contains(first),
              value.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
                      || byte == 45
                      || byte == 95
              })
        else {
            throw BridgeClientError.invalidIdentifier
        }
        return value
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        if normalizedHost == "localhost"
            || normalizedHost == "::1"
            || normalizedHost == "[::1]"
            || normalizedHost == "0:0:0:0:0:0:0:1"
            || normalizedHost == "[0:0:0:0:0:0:0:1]"
        {
            return true
        }

        guard let octets = parseIPv4Address(normalizedHost) else {
            return false
        }
        return octets[0] == 127
    }

    private static func isPrivateIPv4Address(_ host: String) -> Bool {
        guard let octets = parseIPv4Address(host) else {
            return false
        }

        return octets[0] == 10
            || (octets[0] == 172 && (16 ... 31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    private static func parseIPv4Address(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }

        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  part.count <= 3,
                  !(part.count > 1 && part.first == "0"),
                  part.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let value = UInt8(part)
            else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        let normalizedHost = host.lowercased()
        return normalizedHost.count > ".local".count && normalizedHost.hasSuffix(".local")
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

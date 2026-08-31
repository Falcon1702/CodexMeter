import Foundation

enum CodexDirectClientError: LocalizedError, Sendable {
    case invalidProfile
    case invalidResponse
    case responseTooLarge
    case redirectRejected
    case serverRejected(status: Int)
    case loginExpired
    case notAuthenticated
    case reauthenticationRequired
    case accountChanged
    case operationSuperseded

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            "Das Account-Profil ist ungültig."
        case .invalidResponse:
            "OpenAI hat eine unerwartete Antwort geliefert."
        case .responseTooLarge:
            "Die OpenAI-Antwort war unerwartet groß."
        case .redirectRejected:
            "Eine unerwartete Weiterleitung wurde aus Sicherheitsgründen abgelehnt."
        case let .serverRejected(status):
            "OpenAI hat die Anfrage abgelehnt (HTTP \(status))."
        case .loginExpired:
            "Der Anmeldecode ist abgelaufen. Bitte starte die Anmeldung erneut."
        case .notAuthenticated:
            "Dieser Account ist noch nicht angemeldet."
        case .reauthenticationRequired:
            "Die Anmeldung ist abgelaufen. Bitte melde den Account erneut an."
        case .accountChanged:
            "Die erneuerte Anmeldung gehört zu einem anderen Account. Bitte melde dich erneut an."
        case .operationSuperseded:
            "Diese Account-Aktion wurde durch eine neuere Aktion ersetzt."
        }
    }
}

struct CodexDirectAccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var displayName: String

    init(id: String, displayName: String) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexDirectValidation.isProfileID(normalizedID),
              (1 ... 24).contains(normalizedName.count)
        else {
            throw CodexDirectClientError.invalidProfile
        }
        self.id = normalizedID
        self.displayName = normalizedName
    }
}

/// Short-lived state for one device-code ceremony. It intentionally is not Codable,
/// because an unfinished login should never be written to UserDefaults or disk.
struct CodexDirectDeviceLoginSession: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let profile: CodexDirectAccountProfile
    let verificationURL: URL
    let userCode: String
    let pollInterval: TimeInterval
    let expiresAt: Date

    let deviceAuthorizationID: String
    let credentialEpoch: UInt64

    var description: String {
        "CodexDirectDeviceLoginSession(profile: \(profile.id), credentials: <redacted>)"
    }

    var debugDescription: String { description }
}

/// Non-secret state suitable for driving the account UI after a successful login.
struct CodexDirectAccountSession: Codable, Equatable, Sendable {
    let profile: CodexDirectAccountProfile
    let planType: String?
    let authenticatedAt: Date
    let accessTokenExpiresAt: Date?
}

/// Sanitized result of the private Codex usage endpoint.
struct CodexDirectUsage: Codable, Equatable, Sendable {
    let profileID: String
    let planType: String?
    let remainingPercent: Double
    let usedPercent: Double
    let resetsAt: Date
    let windowDurationMinutes: Int
    let resetCredits: Int

    var windowLabel: String {
        guard windowDurationMinutes > 0 else { return "--" }
        if windowDurationMinutes.isMultiple(of: 1_440) {
            return "\(windowDurationMinutes / 1_440)d"
        }
        if windowDurationMinutes.isMultiple(of: 60) {
            return "\(windowDurationMinutes / 60)h"
        }
        return "\(windowDurationMinutes)m"
    }
}

struct CodexDirectCredentials: Codable, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let chatGPTAccountID: String
    let planType: String?
    let isFedRamp: Bool
    let lastRefresh: Date

    var description: String {
        "CodexDirectCredentials(tokens: <redacted>, account: <redacted>)"
    }

    var debugDescription: String { description }
}

struct CodexDirectDeviceCodePayload: Equatable, Sendable {
    let deviceAuthorizationID: String
    let userCode: String
    let interval: TimeInterval
}

struct CodexDirectAuthorizationGrant: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    var description: String {
        "CodexDirectAuthorizationGrant(<redacted>)"
    }

    var debugDescription: String { description }
}

struct CodexDirectTokenExchange: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let idToken: String
    let accessToken: String
    let refreshToken: String

    var description: String {
        "CodexDirectTokenExchange(<redacted>)"
    }

    var debugDescription: String { description }
}

struct CodexDirectTokenRefresh: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    var description: String {
        "CodexDirectTokenRefresh(<redacted>)"
    }

    var debugDescription: String { description }
}

struct CodexDirectJWTClaims: Equatable, Sendable {
    let chatGPTAccountID: String?
    let planType: String?
    let isFedRamp: Bool
    let expiresAt: Date?
}

struct CodexDirectParsedUsage: Equatable, Sendable {
    let planType: String?
    let remainingPercent: Double
    let usedPercent: Double
    let resetsAt: Date
    let windowDurationMinutes: Int
    let resetCredits: Int
}

enum CodexDirectValidation {
    static func isProfileID(_ value: String) -> Bool {
        guard (1 ... 32).contains(value.utf8.count), let first = value.utf8.first else {
            return false
        }
        return isASCIIAlphaNumeric(first) && value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 45 || $0 == 95
        }
    }

    static func isHeaderValue(_ value: String, maximumLength: Int) -> Bool {
        guard (1 ... maximumLength).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { (33 ... 126).contains($0) }
    }

    static func isOpaqueValue(_ value: String, maximumLength: Int = 8_192) -> Bool {
        guard (1 ... maximumLength).contains(value.utf8.count) else { return false }
        return value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func isUserCode(_ value: String) -> Bool {
        guard (4 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { isASCIIAlphaNumeric($0) || $0 == 45 }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte) || (65 ... 90).contains(byte) || (97 ... 122).contains(byte)
    }
}

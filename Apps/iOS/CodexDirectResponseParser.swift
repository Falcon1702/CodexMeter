import Foundation

protocol CodexDirectResponseParsing: Sendable {
    func parseDeviceCode(_ data: Data) throws -> CodexDirectDeviceCodePayload
    func parseAuthorizationGrant(_ data: Data) throws -> CodexDirectAuthorizationGrant
    func parseTokenExchange(_ data: Data) throws -> CodexDirectTokenExchange
    func parseTokenRefresh(_ data: Data) throws -> CodexDirectTokenRefresh
    func parseJWTClaims(_ token: String) throws -> CodexDirectJWTClaims
    func parseUsage(_ data: Data) throws -> CodexDirectParsedUsage
    func parseOAuthErrorCode(_ data: Data) -> String?
}

struct CodexDirectResponseParser: CodexDirectResponseParsing {
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    func parseDeviceCode(_ data: Data) throws -> CodexDirectDeviceCodePayload {
        let response = try decoder.decode(DeviceCodeResponse.self, from: data)
        let trimmedInterval = response.interval.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexDirectValidation.isOpaqueValue(response.deviceAuthorizationID, maximumLength: 2_048),
              CodexDirectValidation.isUserCode(response.userCode),
              let intervalSeconds = UInt64(trimmedInterval),
              intervalSeconds > 0
        else {
            throw CodexDirectClientError.invalidResponse
        }
        return CodexDirectDeviceCodePayload(
            deviceAuthorizationID: response.deviceAuthorizationID,
            userCode: response.userCode,
            interval: TimeInterval(intervalSeconds)
        )
    }

    func parseAuthorizationGrant(_ data: Data) throws -> CodexDirectAuthorizationGrant {
        let response = try decoder.decode(AuthorizationGrantResponse.self, from: data)
        guard CodexDirectValidation.isOpaqueValue(response.authorizationCode),
              CodexDirectValidation.isOpaqueValue(response.codeChallenge),
              CodexDirectValidation.isOpaqueValue(response.codeVerifier)
        else {
            throw CodexDirectClientError.invalidResponse
        }
        return CodexDirectAuthorizationGrant(
            authorizationCode: response.authorizationCode,
            codeChallenge: response.codeChallenge,
            codeVerifier: response.codeVerifier
        )
    }

    func parseTokenExchange(_ data: Data) throws -> CodexDirectTokenExchange {
        let response = try decoder.decode(TokenExchangeResponse.self, from: data)
        guard CodexDirectValidation.isOpaqueValue(response.idToken, maximumLength: 64 * 1_024),
              CodexDirectValidation.isHeaderValue(response.accessToken, maximumLength: 64 * 1_024),
              CodexDirectValidation.isOpaqueValue(response.refreshToken, maximumLength: 64 * 1_024)
        else {
            throw CodexDirectClientError.invalidResponse
        }
        return CodexDirectTokenExchange(
            idToken: response.idToken,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken
        )
    }

    func parseTokenRefresh(_ data: Data) throws -> CodexDirectTokenRefresh {
        let response = try decoder.decode(TokenRefreshResponse.self, from: data)
        try validateOptional(response.idToken, headerValue: false)
        try validateOptional(response.accessToken, headerValue: true)
        try validateOptional(response.refreshToken, headerValue: false)
        return CodexDirectTokenRefresh(
            idToken: response.idToken,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken
        )
    }

    func parseJWTClaims(_ token: String) throws -> CodexDirectJWTClaims {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, !pieces[1].isEmpty, pieces[1].utf8.count <= 64 * 1_024 else {
            throw CodexDirectClientError.invalidResponse
        }

        var payload = String(pieces[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.utf8.count % 4
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload), data.count <= 64 * 1_024 else {
            throw CodexDirectClientError.invalidResponse
        }

        let claims = try decoder.decode(JWTPayload.self, from: data)
        let accountID = claims.auth?.chatGPTAccountID
        if let accountID,
           !CodexDirectValidation.isHeaderValue(accountID, maximumLength: 512)
        {
            throw CodexDirectClientError.invalidResponse
        }
        let planType = sanitizedPlanType(claims.auth?.planType)
        let expiration = claims.expiration.flatMap { value -> Date? in
            guard value.isFinite, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        return CodexDirectJWTClaims(
            chatGPTAccountID: accountID,
            planType: planType,
            isFedRamp: claims.auth?.isFedRamp ?? false,
            expiresAt: expiration
        )
    }

    func parseUsage(_ data: Data) throws -> CodexDirectParsedUsage {
        let response = try decoder.decode(UsageResponse.self, from: data)
        var windows = response.rateLimit?.windows ?? []
        windows.append(contentsOf: response.additionalRateLimits.flatMap { $0.rateLimit?.windows ?? [] })
        guard let limiting = windows.compactMap(normalizedWindow).sorted(by: isMoreLimiting).first else {
            throw CodexDirectClientError.invalidResponse
        }

        let roundedUsed = limiting.usedPercent.rounded()
        return CodexDirectParsedUsage(
            planType: sanitizedPlanType(response.planType),
            remainingPercent: 100 - roundedUsed,
            usedPercent: roundedUsed,
            resetsAt: Date(timeIntervalSince1970: limiting.resetAt),
            windowDurationMinutes: limiting.windowDurationMinutes,
            resetCredits: max(response.resetCredits?.availableCount ?? 0, 0)
        )
    }

    func parseOAuthErrorCode(_ data: Data) -> String? {
        guard data.count <= 64 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let error = object["error"] as? String {
            return error
        }
        if let nested = object["error"] as? [String: Any], let code = nested["code"] as? String {
            return code
        }
        return object["code"] as? String
    }

    private func validateOptional(_ value: String?, headerValue: Bool) throws {
        guard let value else { return }
        let valid = headerValue
            ? CodexDirectValidation.isHeaderValue(value, maximumLength: 64 * 1_024)
            : CodexDirectValidation.isOpaqueValue(value, maximumLength: 64 * 1_024)
        guard valid else { throw CodexDirectClientError.invalidResponse }
    }

    private func normalizedWindow(_ candidate: UsageWindow) -> NormalizedWindow? {
        guard candidate.usedPercent.isFinite,
              candidate.windowSeconds.isFinite,
              candidate.resetAt.isFinite,
              candidate.windowSeconds > 0,
              candidate.resetAt > 0,
              candidate.windowSeconds <= Double(Int.max - 59),
              candidate.resetAt <= 253_402_300_799
        else {
            return nil
        }
        let minutes = Int(ceil(candidate.windowSeconds / 60))
        return NormalizedWindow(
            usedPercent: min(max(candidate.usedPercent, 0), 100),
            windowDurationMinutes: minutes,
            resetAt: candidate.resetAt
        )
    }

    private func isMoreLimiting(_ left: NormalizedWindow, _ right: NormalizedWindow) -> Bool {
        if left.usedPercent != right.usedPercent {
            return left.usedPercent > right.usedPercent
        }
        return left.resetAt < right.resetAt
    }

    private func sanitizedPlanType(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 64).contains(trimmed.utf8.count),
              trimmed.utf8.allSatisfy({
                  (48 ... 57).contains($0)
                      || (65 ... 90).contains($0)
                      || (97 ... 122).contains($0)
                      || $0 == 45
                      || $0 == 95
              })
        else {
            return nil
        }
        return trimmed
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceAuthorizationID: String
    let userCode: String
    let interval: String

    enum CodingKeys: String, CodingKey {
        case deviceAuthorizationID = "device_auth_id"
        case userCode = "user_code"
        case legacyUserCode = "usercode"
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthorizationID = try container.decode(String.self, forKey: .deviceAuthorizationID)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode)
            ?? container.decode(String.self, forKey: .legacyUserCode)
        interval = try container.decode(String.self, forKey: .interval)
    }
}

private struct AuthorizationGrantResponse: Decodable {
    let authorizationCode: String
    let codeChallenge: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }
}

private struct TokenExchangeResponse: Decodable {
    let idToken: String
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct TokenRefreshResponse: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private struct JWTPayload: Decodable {
    let expiration: Double?
    let auth: JWTAuthClaims?

    enum CodingKeys: String, CodingKey {
        case expiration = "exp"
        case auth = "https://api.openai.com/auth"
    }
}

private struct JWTAuthClaims: Decodable {
    let chatGPTAccountID: String?
    let planType: String?
    let isFedRamp: Bool

    enum CodingKeys: String, CodingKey {
        case chatGPTAccountID = "chatgpt_account_id"
        case planType = "chatgpt_plan_type"
        case isFedRamp = "chatgpt_account_is_fedramp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatGPTAccountID = try container.decodeIfPresent(String.self, forKey: .chatGPTAccountID)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        isFedRamp = try container.decodeIfPresent(Bool.self, forKey: .isFedRamp) ?? false
    }
}

private struct UsageResponse: Decodable {
    let planType: String?
    let rateLimit: UsageRateLimit?
    let additionalRateLimits: [AdditionalUsageRateLimit]
    let resetCredits: UsageResetCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case resetCredits = "rate_limit_reset_credits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try container.decodeIfPresent(UsageRateLimit.self, forKey: .rateLimit)
        additionalRateLimits = try container.decodeIfPresent(
            [AdditionalUsageRateLimit].self,
            forKey: .additionalRateLimits
        ) ?? []
        resetCredits = try container.decodeIfPresent(UsageResetCredits.self, forKey: .resetCredits)
    }
}

private struct AdditionalUsageRateLimit: Decodable {
    let rateLimit: UsageRateLimit?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct UsageRateLimit: Decodable {
    let primaryWindow: UsageWindow?
    let secondaryWindow: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    var windows: [UsageWindow] {
        [primaryWindow, secondaryWindow].compactMap { $0 }
    }
}

private struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowSeconds: Double
    let resetAt: Double

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private struct UsageResetCredits: Decodable {
    let availableCount: Int

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
    }
}

private struct NormalizedWindow {
    let usedPercent: Double
    let windowDurationMinutes: Int
    let resetAt: Double
}

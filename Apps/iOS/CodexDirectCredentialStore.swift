import Foundation
import Security

protocol CodexDirectCredentialStoring: Sendable {
    func load(profileID: String) async throws -> CodexDirectCredentials?
    func save(_ credentials: CodexDirectCredentials, profileID: String) async throws
    func delete(profileID: String) async throws
}

enum CodexDirectCredentialStoreError: LocalizedError, Sendable {
    case invalidProfileID
    case invalidStoredData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidProfileID:
            "Das Account-Profil ist ungültig."
        case .invalidStoredData:
            "Die lokal gespeicherte Anmeldung ist beschädigt."
        case .keychain:
            "Die Anmeldung konnte nicht sicher im iPhone-Schlüsselbund verarbeitet werden."
        }
    }
}

actor CodexDirectKeychainCredentialStore: CodexDirectCredentialStoring {
    private struct Envelope: Codable {
        let version: Int
        let credentials: CodexDirectCredentials
    }

    private let service: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        service: String = "com.example.codexmeter.codex-direct",
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.service = service
        self.encoder = encoder
        self.decoder = decoder
    }

    func load(profileID: String) async throws -> CodexDirectCredentials? {
        try validate(profileID)
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CodexDirectCredentialStoreError.keychain(status)
        }
        guard let data = result as? Data, data.count <= 256 * 1_024,
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1
        else {
            throw CodexDirectCredentialStoreError.invalidStoredData
        }
        return envelope.credentials
    }

    func save(_ credentials: CodexDirectCredentials, profileID: String) async throws {
        try validate(profileID)
        let envelope = Envelope(version: 1, credentials: credentials)
        let data = try encoder.encode(envelope)
        guard data.count <= 256 * 1_024 else {
            throw CodexDirectCredentialStoreError.invalidStoredData
        }

        let base = baseQuery(profileID: profileID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexDirectCredentialStoreError.keychain(updateStatus)
        }

        var insert = base
        attributes.forEach { insert[$0.key] = $0.value }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexDirectCredentialStoreError.keychain(addStatus)
        }
    }

    func delete(profileID: String) async throws {
        try validate(profileID)
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexDirectCredentialStoreError.keychain(status)
        }
    }

    private func validate(_ profileID: String) throws {
        guard CodexDirectValidation.isProfileID(profileID) else {
            throw CodexDirectCredentialStoreError.invalidProfileID
        }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

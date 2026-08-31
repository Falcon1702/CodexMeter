import Foundation
import UsageCore

struct AccountBrandStore {
    private enum StoredBrand: String, Codable {
        case letter
        case codex
        case hermes
        case openClaw
        case buzz

        init(_ brand: UsageServiceBrand?) {
            switch brand {
            case .codex:
                self = .codex
            case .hermes:
                self = .hermes
            case .openClaw:
                self = .openClaw
            case .buzz:
                self = .buzz
            case nil:
                self = .letter
            }
        }

        var serviceBrand: UsageServiceBrand? {
            switch self {
            case .letter: nil
            case .codex: .codex
            case .hermes: .hermes
            case .openClaw: .openClaw
            case .buzz: .buzz
            }
        }
    }

    private struct Payload: Codable {
        private struct AccountIDKey: CodingKey {
            let stringValue: String
            let intValue: Int? = nil

            init?(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue _: Int) {
                return nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case selections
        }

        var schemaVersion: Int
        var selections: [String: StoredBrand]

        init() {
            schemaVersion = 1
            selections = [:]
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
            selections = [:]

            guard let storedSelections = try? container.nestedContainer(
                keyedBy: AccountIDKey.self,
                forKey: .selections
            ) else {
                return
            }

            for key in storedSelections.allKeys {
                guard let rawValue = try? storedSelections.decode(String.self, forKey: key),
                      let brand = StoredBrand(rawValue: rawValue)
                else {
                    continue
                }
                selections[key.stringValue] = brand
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            var storedSelections = container.nestedContainer(
                keyedBy: AccountIDKey.self,
                forKey: .selections
            )
            for (accountID, brand) in selections {
                guard let key = AccountIDKey(stringValue: accountID) else { continue }
                try storedSelections.encode(brand.rawValue, forKey: key)
            }
        }
    }

    private static let defaultsKey = "accountServiceBrands.v1"

    private let defaults: UserDefaults
    private var payload: Payload

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.schemaVersion == 1
        {
            payload = decoded
        } else {
            payload = Payload()
        }
    }

    func serviceBrand(for accountID: String) -> UsageServiceBrand? {
        payload.selections[accountID]?.serviceBrand
    }

    mutating func setServiceBrand(
        _ serviceBrand: UsageServiceBrand?,
        for accountID: String
    ) throws {
        var updated = payload
        updated.selections[accountID] = StoredBrand(serviceBrand)
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.defaultsKey)
        payload = updated
    }
}

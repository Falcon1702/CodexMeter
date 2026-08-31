import Foundation

public enum UsageSnapshotCodecError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(expected, actual):
            "Unsupported usage snapshot schema version \(actual); expected \(expected)."
        }
    }
}

public enum UsageSnapshotCodec {
    public static let supportedSchemaVersion = 1

    public static func decode(_ data: Data) throws -> UsageSnapshot {
        let snapshot = try makeDecoder().decode(UsageSnapshot.self, from: data)
        try validateSchemaVersion(snapshot.schemaVersion)
        return snapshot
    }

    public static func encode(_ snapshot: UsageSnapshot) throws -> Data {
        try validateSchemaVersion(snapshot.schemaVersion)
        return try makeEncoder().encode(snapshot)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = makeISO8601Formatter(withFractionalSeconds: true).date(from: value)
                ?? makeISO8601Formatter(withFractionalSeconds: false).date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp, received \(value)"
            )
        }
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                makeISO8601Formatter(withFractionalSeconds: true).string(from: date)
            )
        }
        return encoder
    }

    private static func makeISO8601Formatter(
        withFractionalSeconds: Bool
    ) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func validateSchemaVersion(_ actualVersion: Int) throws {
        guard actualVersion == supportedSchemaVersion else {
            throw UsageSnapshotCodecError.unsupportedSchemaVersion(
                expected: supportedSchemaVersion,
                actual: actualVersion
            )
        }
    }
}

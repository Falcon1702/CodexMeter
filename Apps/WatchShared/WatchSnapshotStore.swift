import Foundation
import UsageCore

enum WatchOverlaySharedConstants {
    static let appGroupIdentifier = "group.com.example.codexmeter"
    static let widgetKind = "com.example.codexmeter.usage"
}

enum WatchSnapshotStore {
    private static let filename = "usage-snapshot-v1.json"

    static func load() -> UsageSnapshot? {
        guard let url = fileURL(), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? UsageSnapshotCodec.decode(data).normalized(maxAccounts: 3)
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try UsageSnapshotCodec.encode(snapshot.normalized(maxAccounts: 3))
        try data.write(to: url, options: .atomic)
    }

    private static func fileURL() -> URL? {
        FileManager.default
            .containerURL(
                forSecurityApplicationGroupIdentifier: WatchOverlaySharedConstants.appGroupIdentifier
            )?
            .appendingPathComponent(filename)
    }
}

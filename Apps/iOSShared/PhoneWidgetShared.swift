import Foundation
import UsageCore

enum PhoneWidgetShared {
    static let appGroupIdentifier = "group.com.example.codexmeter"
    static let widgetKind = "com.example.codexmeter.usage.phone"
    static let snapshotFilename = "usage-snapshot-v1.json"

    static func loadSnapshot() -> UsageSnapshot? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        let url = container.appendingPathComponent(snapshotFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? UsageSnapshotCodec.decode(data).normalized(maxAccounts: 3)
    }
}

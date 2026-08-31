import Foundation
import UsageCore
import WidgetKit

enum PhoneSnapshotStore {
    private static let filename = PhoneWidgetShared.snapshotFilename

    static func load() -> UsageSnapshot? {
        guard let url = storageURL(),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? UsageSnapshotCodec.decode(data)
    }

    static func save(_ snapshot: UsageSnapshot) throws {
        guard let url = fileURL(named: filename) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try UsageSnapshotCodec.encode(snapshot)
        try data.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadTimelines(ofKind: PhoneWidgetShared.widgetKind)
    }

    private static func storageURL() -> URL? {
        fileURL(named: filename)
    }

    static func fileURL(named filename: String) -> URL? {
        if let shared = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PhoneWidgetShared.appGroupIdentifier
        ) {
            return shared.appendingPathComponent(filename)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("WatchOverlay", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

final class ResetEventOutboxStore: @unchecked Sendable {
    static let shared = ResetEventOutboxStore()

    private let filename = "reset-event-outbox-v1.json"
    private let lock = NSLock()

    func load() throws -> [ResetEvent] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func append(_ events: [ResetEvent]) throws {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let merged = merge(try loadUnlocked(), events)
        try saveUnlocked(merged)
    }

    func remove(identifiers: Set<String>) throws {
        guard !identifiers.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = try loadUnlocked().filter {
            !identifiers.contains($0.stableID)
        }
        try saveUnlocked(remaining)
    }

    private func loadUnlocked() throws -> [ResetEvent] {
        guard let url = PhoneSnapshotStore.fileURL(named: filename) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ResetEvent].self, from: Data(contentsOf: url))
    }

    private func saveUnlocked(_ events: [ResetEvent]) throws {
        guard let url = PhoneSnapshotStore.fileURL(named: filename) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }

    private func merge(_ older: [ResetEvent], _ newer: [ResetEvent]) -> [ResetEvent] {
        var seen = Set<String>()
        return (older + newer).filter {
            seen.insert($0.stableID).inserted
        }
    }
}

import Foundation

actor SnapshotCacheWriter<Value: Encodable & Sendable> {
    private var latestRevision: UInt64 = 0

    func save(_ value: Value, to url: URL?, revision: UInt64) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    func remove(at url: URL?, revision: UInt64) {
        guard revision >= latestRevision else { return }
        latestRevision = revision
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

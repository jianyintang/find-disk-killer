import CFindDiskKiller
import Foundation

public struct FileChangeLookup: Sendable {
    public let latestByPath: [String: Date]
    public let statusByPath: [String: FileChangeObservationStatus]
    public let hasCoverageGap: Bool
    public let observedSince: Date?
}

public enum FileChangeObservationStatus: Equatable, Sendable {
    case observing
    case unavailable
}

public enum RecentFileChangeRetention {
    public static func retainedTimestamp(
        previous: Date?,
        observed: Date?,
        now: Date,
        window: TimeInterval = FileChangeWatcher.recentChangeWindow
    ) -> Date? {
        guard let newest = [previous, observed].compactMap({ $0 }).max(),
              newest >= now.addingTimeInterval(-window)
        else { return nil }
        return newest
    }
}

public actor FileChangeWatcher {
    public static let shared = FileChangeWatcher()
    public nonisolated static let recentChangeWindow: TimeInterval = 300

    private struct Stream: @unchecked Sendable {
        let volumeID: String
        let mountPath: String
        let pointer: OpaquePointer
        let startedAt: Date
    }

    private struct ObservedChange {
        let path: String
        let volumeID: String
        let observedAt: Date
    }

    private struct VolumeScope {
        let volumeID: String
        let mountPath: String
        let isObservable: Bool
    }

    private var streams: [String: Stream] = [:]
    private var history: [ObservedChange] = []
    private var gapObservedAt: [String: Date] = [:]
    private var volumeScopes: [VolumeScope] = []
    private var activeLeases: Set<UUID> = []

    deinit {
        for stream in streams.values {
            dm_fsevent_watcher_destroy(stream.pointer)
        }
    }

    public func configure(volumes: [VolumeInfo]) {
        volumeScopes = volumes
            .filter { $0.mountPath.hasPrefix("/") }
            .map { volume in
                VolumeScope(
                    volumeID: volume.id,
                    mountPath: Self.canonicalPath(volume.mountPath),
                    isObservable: volume.isLocal && volume.isWritable
                        && volume.hasStableIdentity
                )
            }
        let eligible = Dictionary(uniqueKeysWithValues: volumes
            .filter {
                $0.isLocal && $0.isWritable && $0.hasStableIdentity
                    && $0.mountPath.hasPrefix("/")
            }
            .map { ($0.id, $0) })

        let removedIDs = streams.keys.filter { id in
            guard let volume = eligible[id], let stream = streams[id] else { return true }
            return stream.mountPath != Self.canonicalPath(volume.mountPath)
        }
        for id in removedIDs {
            guard let stream = streams[id] else { continue }
            dm_fsevent_watcher_destroy(stream.pointer)
            streams.removeValue(forKey: id)
            gapObservedAt.removeValue(forKey: id)
            history.removeAll { $0.volumeID == id }
        }

        for (id, volume) in eligible where streams[id] == nil {
            streams[id] = makeStream(volumeID: id, mountPath: volume.mountPath)
        }
    }

    public func beginSession(volumes: [VolumeInfo]) -> UUID {
        let lease = UUID()
        let alreadyHadSession = !activeLeases.isEmpty
        activeLeases.insert(lease)
        if !volumes.isEmpty || !alreadyHadSession {
            configure(volumes: volumes)
        }
        return lease
    }

    public func endSession(_ lease: UUID) {
        guard activeLeases.remove(lease) != nil, activeLeases.isEmpty else { return }
        for stream in streams.values {
            dm_fsevent_watcher_destroy(stream.pointer)
        }
        streams.removeAll()
        history.removeAll()
        gapObservedAt.removeAll()
        volumeScopes.removeAll()
    }

    func injectGapForTesting(volumeID: String) {
        guard let stream = streams[volumeID] else { return }
        dm_fsevent_watcher_force_gap(stream.pointer)
    }

    func injectHistoryOverflowForTesting(volumeID: String) {
        guard let stream = streams[volumeID] else { return }
        history.append(contentsOf: (0..<10_001).map { index in
            ObservedChange(
                path: stream.mountPath + "/fixture-\(index)",
                volumeID: volumeID,
                observedAt: Date()
            )
        })
    }

    public func recentChanges(
        for paths: [String],
        within interval: TimeInterval = FileChangeWatcher.recentChangeWindow
    ) -> FileChangeLookup {
        poll()
        let now = Date()
        let cutoff = now.addingTimeInterval(-interval)
        history.removeAll { $0.observedAt < cutoff }

        var latest: [String: Date] = [:]
        var statuses: [String: FileChangeObservationStatus] = [:]
        var relevantVolumes: Set<String> = []
        for originalPath in paths {
            let path = Self.canonicalPath(originalPath)
            guard let scope = volumeScopes
                .filter({ Self.contains(path: path, in: $0.mountPath) })
                .max(by: { $0.mountPath.count < $1.mountPath.count })
            else {
                statuses[originalPath] = .unavailable
                continue
            }
            guard scope.isObservable, let stream = streams[scope.volumeID] else {
                statuses[originalPath] = .unavailable
                continue
            }
            statuses[originalPath] = .observing
            relevantVolumes.insert(stream.volumeID)
            for change in history where change.volumeID == stream.volumeID
                && (change.path == path || change.path.hasPrefix(path + "/")) {
                latest[originalPath] = max(
                    latest[originalPath] ?? .distantPast,
                    change.observedAt
                )
            }
        }

        let observedSince = streams.values
            .filter { relevantVolumes.contains($0.volumeID) }
            .map(\.startedAt)
            .min()
        return FileChangeLookup(
            latestByPath: latest,
            statusByPath: statuses,
            hasCoverageGap: relevantVolumes.contains { volumeID in
                gapObservedAt[volumeID].map { $0 >= cutoff } ?? false
            },
            observedSince: observedSince
        )
    }

    private func poll() {
        let observedAt = Date()
        var streamsToRestart: [String] = []
        for stream in Array(streams.values) {
            var buffer = Array(repeating: DMFileChangeEvent(), count: 4_096)
            var hadGap: Int32 = 0
            let count = Int(dm_fsevent_watcher_drain(
                stream.pointer,
                &buffer,
                Int32(buffer.count),
                &hadGap
            ))
            if hadGap != 0 {
                gapObservedAt[stream.volumeID] = observedAt
                streamsToRestart.append(stream.volumeID)
            }
            history.append(contentsOf: buffer.prefix(max(0, count)).compactMap { raw in
                var raw = raw
                let path = Self.canonicalPath(decodeFileChangePath(&raw.path))
                guard !path.isEmpty else { return nil }
                return ObservedChange(
                    path: path,
                    volumeID: stream.volumeID,
                    observedAt: observedAt
                )
            })
        }
        if history.count > 10_000 {
            let overflow = history.count - 10_000
            let affectedVolumes = Set(history.prefix(overflow).map(\.volumeID))
            history.removeFirst(overflow)
            for volumeID in affectedVolumes {
                gapObservedAt[volumeID] = observedAt
                streamsToRestart.append(volumeID)
            }
        }
        for volumeID in streamsToRestart {
            restartStream(volumeID: volumeID)
        }
    }

    private func restartStream(volumeID: String) {
        guard let old = streams.removeValue(forKey: volumeID) else { return }
        dm_fsevent_watcher_destroy(old.pointer)
        streams[volumeID] = makeStream(volumeID: volumeID, mountPath: old.mountPath)
    }

    private func makeStream(volumeID: String, mountPath: String) -> Stream? {
        let path = Self.canonicalPath(mountPath)
        guard let pointer = path.withCString({ dm_fsevent_watcher_create($0) }) else {
            return nil
        }
        guard dm_fsevent_watcher_start(pointer) != 0 else {
            dm_fsevent_watcher_destroy(pointer)
            return nil
        }
        return Stream(
            volumeID: volumeID,
            mountPath: path,
            pointer: pointer,
            startedAt: Date()
        )
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    nonisolated private static func contains(path: String, in mountPath: String) -> Bool {
        mountPath == "/" || path == mountPath || path.hasPrefix(mountPath + "/")
    }
}

private func decodeFileChangePath<T>(_ value: inout T) -> String {
    withUnsafeBytes(of: &value) { rawBuffer in
        let bytes = rawBuffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}

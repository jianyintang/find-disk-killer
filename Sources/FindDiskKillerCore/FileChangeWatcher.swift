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
    private nonisolated static let eventBufferCapacity = 512
    private nonisolated static let maximumHistoryCount = 4_096
    private nonisolated static let maximumWatchedPathsPerVolume = 512

    private struct Stream: @unchecked Sendable {
        let volumeID: String
        let mountPath: String
        let watchedPaths: Set<String>
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
        history.append(contentsOf: (0...Self.maximumHistoryCount).map { index in
            ObservedChange(
                path: stream.mountPath + "/fixture-\(index)",
                volumeID: volumeID,
                observedAt: Date()
            )
        })
    }

    func watchedPathsForTesting(volumeID: String) -> Set<String> {
        streams[volumeID]?.watchedPaths ?? []
    }

    public func recentChanges(
        for paths: [String],
        within interval: TimeInterval = FileChangeWatcher.recentChangeWindow
    ) -> FileChangeLookup {
        poll()
        let canonicalPaths = paths.map { ($0, Self.canonicalPath($0)) }
        let requestedByVolume = requestedWatchPaths(for: canonicalPaths.map { $0.1 })
        reconcileStreams(with: requestedByVolume)
        let now = Date()
        let cutoff = now.addingTimeInterval(-interval)
        history.removeAll { $0.observedAt < cutoff }

        var latest: [String: Date] = [:]
        var statuses: [String: FileChangeObservationStatus] = [:]
        var relevantVolumes: Set<String> = []
        for (originalPath, path) in canonicalPaths {
            guard let scope = volumeScopes
                .filter({ Self.contains(path: path, in: $0.mountPath) })
                .max(by: { $0.mountPath.count < $1.mountPath.count })
            else {
                statuses[originalPath] = .unavailable
                continue
            }
            guard scope.isObservable,
                  let stream = streams[scope.volumeID],
                  stream.watchedPaths.contains(path)
            else {
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
        var streamsToRestart: Set<String> = []
        var buffer = Array(
            repeating: DMFileChangeEvent(),
            count: Self.eventBufferCapacity
        )
        for stream in Array(streams.values) {
            var hadGap: Int32 = 0
            let count = Int(dm_fsevent_watcher_drain(
                stream.pointer,
                &buffer,
                Int32(buffer.count),
                &hadGap
            ))
            if hadGap != 0 {
                gapObservedAt[stream.volumeID] = observedAt
                streamsToRestart.insert(stream.volumeID)
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
        if history.count > Self.maximumHistoryCount {
            let overflow = history.count - Self.maximumHistoryCount
            let affectedVolumes = Set(history.prefix(overflow).map(\.volumeID))
            history.removeFirst(overflow)
            for volumeID in affectedVolumes {
                gapObservedAt[volumeID] = observedAt
                streamsToRestart.insert(volumeID)
            }
        }
        for volumeID in streamsToRestart {
            restartStream(volumeID: volumeID)
        }
    }

    private func restartStream(volumeID: String) {
        guard let old = streams.removeValue(forKey: volumeID) else { return }
        dm_fsevent_watcher_destroy(old.pointer)
        streams[volumeID] = makeStream(
            volumeID: volumeID,
            mountPath: old.mountPath,
            watchedPaths: old.watchedPaths
        )
    }

    private func requestedWatchPaths(for paths: [String]) -> [String: Set<String>] {
        var requested: [String: Set<String>] = [:]
        for path in paths {
            guard let scope = volumeScopes
                .filter({ $0.isObservable && Self.contains(path: path, in: $0.mountPath) })
                .max(by: { $0.mountPath.count < $1.mountPath.count })
            else { continue }
            requested[scope.volumeID, default: []].insert(path)
        }
        return requested.mapValues { paths in
            Set(paths.sorted().prefix(Self.maximumWatchedPathsPerVolume))
        }
    }

    private func reconcileStreams(with requestedByVolume: [String: Set<String>]) {
        let removedVolumeIDs = streams.keys.filter { requestedByVolume[$0]?.isEmpty != false }
        for volumeID in removedVolumeIDs {
            guard let stream = streams.removeValue(forKey: volumeID) else { continue }
            dm_fsevent_watcher_destroy(stream.pointer)
            history.removeAll { $0.volumeID == volumeID }
            gapObservedAt.removeValue(forKey: volumeID)
        }

        for (volumeID, watchedPaths) in requestedByVolume where !watchedPaths.isEmpty {
            guard let scope = volumeScopes.first(where: { $0.volumeID == volumeID }) else { continue }
            if streams[volumeID]?.watchedPaths == watchedPaths { continue }
            guard let replacement = makeStream(
                volumeID: volumeID,
                mountPath: scope.mountPath,
                watchedPaths: watchedPaths
            ) else { continue }
            let old = streams.updateValue(replacement, forKey: volumeID)
            if let old {
                dm_fsevent_watcher_destroy(old.pointer)
            }
            history.removeAll { change in
                change.volumeID == volumeID && !watchedPaths.contains { watchedPath in
                    Self.contains(path: change.path, in: watchedPath)
                }
            }
        }
    }

    private func makeStream(
        volumeID: String,
        mountPath: String,
        watchedPaths: Set<String>
    ) -> Stream? {
        let path = Self.canonicalPath(mountPath)
        let retainedPaths = watchedPaths.sorted().map { $0 as NSString }
        let pointers = retainedPaths.map(\.utf8String)
        guard let pointer = pointers.withUnsafeBufferPointer({ buffer in
            dm_fsevent_watcher_create_paths(buffer.baseAddress, Int32(buffer.count))
        }) else {
            return nil
        }
        guard dm_fsevent_watcher_start(pointer) != 0 else {
            dm_fsevent_watcher_destroy(pointer)
            return nil
        }
        return Stream(
            volumeID: volumeID,
            mountPath: path,
            watchedPaths: watchedPaths,
            pointer: pointer,
            startedAt: Date()
        )
    }

    nonisolated private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
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

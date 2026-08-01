import Darwin
import Foundation

struct DockerStorageInventory: Sendable {
    let nodes: [StorageResourceNode]
    let diagnostic: String?
}

enum DockerStorageInspectorError: Error {
    case unavailable
    case commandFailed(Int32)
    case malformedOutput
    case outputTooLarge
    case timedOut
}

struct DockerStorageInspector: Sendable {
    typealias Runner = @Sendable () async throws -> Data
    private let runner: Runner

    init(runner: @escaping Runner = DockerStorageInspector.runDockerSystemDF) {
        self.runner = runner
    }

    func inspect() async -> DockerStorageInventory {
        do {
            let data = try await runner()
            return DockerStorageInventory(nodes: try Self.parse(data), diagnostic: nil)
        } catch {
            return DockerStorageInventory(
                nodes: [],
                diagnostic: "Docker Engine inventory was unavailable"
            )
        }
    }

    static func parse(_ data: Data) throws -> [StorageResourceNode] {
        let report = try JSONDecoder().decode(DockerSystemDFReport.self, from: data)
        let imageNodes = report.images.map { image in
            let title = image.repository.isEmpty || image.repository == "<none>"
                ? String(image.id.prefix(19))
                : "\(image.repository):\(image.tag.isEmpty ? "latest" : image.tag)"
            let unique = parseSize(image.uniqueSize) ?? parseSize(image.size) ?? 0
            let shared = parseSize(image.sharedSize) ?? 0
            let virtual = parseSize(image.virtualSize) ?? parseSize(image.size) ?? 0
            return StorageResourceNode(
                id: "docker.image.\(image.id)",
                kind: .dockerImage,
                title: title,
                detail: "独占 \(formatBytes(unique)) · 共享 \(formatBytes(shared)) · 虚拟 \(formatBytes(virtual)) · \(image.containers) 个容器",
                symbol: "shippingbox.fill",
                allocatedBytes: unique,
                logicalBytes: virtual,
                entryCount: 1,
                risk: .environmentOrRuntime,
                evidence: .providerReported,
                isProtected: image.containers != "0",
                cleanupTarget: image.containers == "0" ? .dockerImage(id: image.id) : nil
            )
        }
        .sorted(by: resourceOrder)

        let containerNodes = report.containers.map { container in
            let bytes = parseSize(container.size) ?? 0
            let isRunning = container.state.caseInsensitiveCompare("running") == .orderedSame
            return StorageResourceNode(
                id: "docker.container.\(container.id)",
                kind: .dockerContainer,
                title: container.names.isEmpty ? String(container.id.prefix(12)) : container.names,
                detail: "\(container.image) · \(container.status)",
                symbol: isRunning ? "play.circle.fill" : "stop.circle",
                allocatedBytes: bytes,
                logicalBytes: bytes,
                entryCount: 1,
                risk: .environmentOrRuntime,
                evidence: .providerReported,
                isProtected: isRunning,
                cleanupTarget: isRunning ? nil : .dockerContainer(id: container.id)
            )
        }
        .sorted(by: resourceOrder)

        let volumeNodes = report.volumes.map { volume in
            let bytes = parseSize(volume.size) ?? 0
            let isInUse = Int(volume.links) ?? 0 > 0
            return StorageResourceNode(
                id: "docker.volume.\(volume.name)",
                kind: .dockerVolume,
                title: volume.name,
                detail: isInUse ? "被 \(volume.links) 个容器引用" : "当前未被容器引用",
                symbol: "externaldrive.fill",
                allocatedBytes: bytes,
                logicalBytes: bytes,
                entryCount: 1,
                risk: .protectedUserData,
                evidence: .providerReported,
                isProtected: true,
                cleanupTarget: isInUse ? nil : .dockerVolume(name: volume.name)
            )
        }
        .sorted(by: resourceOrder)

        let cacheNodes = report.buildCache.map { cache in
            let bytes = parseSize(cache.size) ?? 0
            let detailParts = [
                cache.description.isEmpty ? nil : cache.description,
                cache.inUse == "true" ? "正在使用" : "未使用",
                cache.lastUsedSince.isEmpty ? nil : cache.lastUsedSince
            ].compactMap { $0 }
            return StorageResourceNode(
                id: "docker.build-cache.\(cache.id)",
                kind: .dockerBuildCacheRecord,
                title: cache.description.isEmpty ? String(cache.id.prefix(12)) : cache.description,
                detail: detailParts.joined(separator: " · "),
                symbol: "hammer.fill",
                allocatedBytes: bytes,
                logicalBytes: bytes,
                entryCount: 1,
                risk: .rebuildableCache,
                evidence: .providerReported,
                isProtected: cache.inUse == "true"
            )
        }
        .sorted(by: resourceOrder)

        return [
            group(
                id: "docker.engine.images",
                kind: .dockerImages,
                title: "镜像",
                symbol: "shippingbox.fill",
                children: imageNodes,
                risk: .environmentOrRuntime
            ),
            group(
                id: "docker.engine.containers",
                kind: .dockerContainers,
                title: "容器",
                symbol: "cube.fill",
                children: containerNodes,
                risk: .environmentOrRuntime
            ),
            group(
                id: "docker.engine.volumes",
                kind: .dockerVolumes,
                title: "Volumes",
                symbol: "externaldrive.fill",
                children: volumeNodes,
                risk: .protectedUserData
            ),
            group(
                id: "docker.engine.build-cache",
                kind: .dockerBuildCache,
                title: "构建缓存",
                symbol: "hammer.fill",
                children: cacheNodes,
                risk: .rebuildableCache
            )
        ]
    }

    private static func group(
        id: String,
        kind: StorageResourceKind,
        title: String,
        symbol: String,
        children: [StorageResourceNode],
        risk: StorageRiskLevel
    ) -> StorageResourceNode {
        StorageResourceNode(
            id: id,
            kind: kind,
            title: title,
            detail: "\(children.count) 项 · Docker Engine 报告，组间可能共享底层数据",
            symbol: symbol,
            allocatedBytes: children.reduce(UInt64.zero) { sumClamped($0, $1.allocatedBytes) },
            logicalBytes: children.reduce(UInt64.zero) { sumClamped($0, $1.logicalBytes) },
            entryCount: children.count,
            risk: risk,
            evidence: .providerReported,
            isProtected: children.contains(where: \.isProtected),
            children: children
        )
    }

    private static func resourceOrder(_ lhs: StorageResourceNode, _ rhs: StorageResourceNode) -> Bool {
        if lhs.allocatedBytes != rhs.allocatedBytes { return lhs.allocatedBytes > rhs.allocatedBytes }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private static func sumClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    static func parseSize(_ rawValue: String) -> UInt64? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let scanner = Scanner(string: value)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let number = scanner.scanDouble() else { return nil }
        let suffix = String(value[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch suffix.lowercased() {
        case "b", "": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        guard number >= 0, number * multiplier <= Double(UInt64.max) else { return nil }
        return UInt64(number * multiplier)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func runDockerSystemDF() async throws -> Data {
        guard let executable = dockerExecutable() else { throw DockerStorageInspectorError.unavailable }
        return try await DockerCommandRunner().run(
            executableURL: executable,
            arguments: ["system", "df", "-v", "--format", "{{json .}}"],
            timeout: .seconds(12),
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
    }

    private static func dockerExecutable() -> URL? {
        [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

private struct DockerSystemDFReport: Decodable {
    let images: [DockerImageRecord]
    let containers: [DockerContainerRecord]
    let volumes: [DockerVolumeRecord]
    let buildCache: [DockerBuildCacheRecord]

    private enum CodingKeys: String, CodingKey {
        case images = "Images"
        case containers = "Containers"
        case volumes = "Volumes"
        case buildCache = "BuildCache"
    }
}

private struct DockerImageRecord: Decodable {
    let id: String
    let repository: String
    let tag: String
    let containers: String
    let size: String
    let sharedSize: String
    let uniqueSize: String
    let virtualSize: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case containers = "Containers"
        case size = "Size"
        case sharedSize = "SharedSize"
        case uniqueSize = "UniqueSize"
        case virtualSize = "VirtualSize"
    }
}

private struct DockerContainerRecord: Decodable {
    let id: String
    let names: String
    let image: String
    let state: String
    let status: String
    let size: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case size = "Size"
    }
}

private struct DockerVolumeRecord: Decodable {
    let name: String
    let links: String
    let size: String

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case links = "Links"
        case size = "Size"
    }
}

private struct DockerBuildCacheRecord: Decodable {
    let id: String
    let description: String
    let size: String
    let inUse: String
    let lastUsedSince: String

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case description = "Description"
        case size = "Size"
        case inUse = "InUse"
        case lastUsedSince = "LastUsedSince"
    }
}

private actor DockerCommandRunner {
    func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws -> Data {
        let process = Process()
        let output = Pipe()
        let termination = DockerProcessTermination()
        let runState = DockerRunState()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { termination.complete(with: $0.terminationStatus) }
        try process.run()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var data = Data()
                    for try await byte in output.fileHandleForReading.bytes {
                        data.append(byte)
                        if data.count > maximumOutputBytes {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            _ = await termination.status()
                            throw DockerStorageInspectorError.outputTooLarge
                        }
                    }
                    let status = await termination.status()
                    if runState.didTimeOut { throw DockerStorageInspectorError.timedOut }
                    guard status == 0 else { throw DockerStorageInspectorError.commandFailed(status) }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    runState.markTimedOut()
                    if process.isRunning { process.terminate() }
                    try? await Task.sleep(for: .milliseconds(200))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw DockerStorageInspectorError.timedOut
                }
                guard let data = try await group.next() else {
                    throw DockerStorageInspectorError.malformedOutput
                }
                group.cancelAll()
                return data
            }
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

private final class DockerProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var statusValue: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func complete(with status: Int32) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard statusValue == nil else { return [] }
            statusValue = status
            defer { continuations.removeAll() }
            return continuations
        }
        waiting.forEach { $0.resume(returning: status) }
    }

    func status() async -> Int32 {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Int32? in
                if let statusValue { return statusValue }
                continuations.append(continuation)
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }
}

private final class DockerRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var didTimeOut: Bool { lock.withLock { value } }
    func markTimedOut() { lock.withLock { value = true } }
}

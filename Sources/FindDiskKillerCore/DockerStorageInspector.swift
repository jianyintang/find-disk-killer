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
    typealias ImageInspectionRunner = @Sendable () async throws -> [DockerImageInspection]
    private let runner: Runner
    private let imageInspectionRunner: ImageInspectionRunner
    private let fallbackRunner: Runner

    init(
        runner: @escaping Runner = DockerStorageInspector.runDockerSystemDF,
        imageInspectionRunner: @escaping ImageInspectionRunner = DockerStorageInspector.runDockerImageInspections,
        fallbackRunner: @escaping Runner = DockerStorageInspector.runDockerObjectLists
    ) {
        self.runner = runner
        self.imageInspectionRunner = imageInspectionRunner
        self.fallbackRunner = fallbackRunner
    }

    func inspect() async -> DockerStorageInventory {
        do {
            async let reportData = runner()
            async let inspections = imageInspectionRunner()
            let data = try await reportData
            let referenceMap = try? await Dictionary(
                uniqueKeysWithValues: inspections.map { inspection in
                    (inspection.id, inspection.references)
                }
            )
            return DockerStorageInventory(
                nodes: try Self.parse(data, imageReferencesByID: referenceMap),
                diagnostic: referenceMap == nil
                    ? "Docker image references could not be verified"
                    : nil
            )
        } catch {
            if let fallbackData = try? await fallbackRunner() {
                let references = try? await imageInspectionRunner()
                let referenceMap = references.map { inspections in
                    Dictionary(uniqueKeysWithValues: inspections.map { ($0.id, $0.references) })
                }
                if let nodes = try? Self.parseFallback(
                    fallbackData,
                    imageReferencesByID: referenceMap
                ) {
                    return DockerStorageInventory(
                        nodes: nodes,
                        diagnostic: "Docker Engine 容量报告不可用，已使用对象清单"
                    )
                }
            }
            return DockerStorageInventory(
                nodes: [],
                diagnostic: "Docker Engine inventory was unavailable"
            )
        }
    }

    static func parse(
        _ data: Data,
        imageReferencesByID: [String: [String]]? = nil
    ) throws -> [StorageResourceNode] {
        let report = try JSONDecoder().decode(DockerSystemDFReport.self, from: data)
        let imageNodes = Dictionary(grouping: report.images, by: \.id).map { id, records in
            let reportedReferences = records.compactMap { image -> String? in
                guard !image.repository.isEmpty, image.repository != "<none>" else { return nil }
                return "\(image.repository):\(image.tag.isEmpty ? "latest" : image.tag)"
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let verifiedReferences = imageReferencesByID?[id]
            let references = verifiedReferences ?? reportedReferences
            let referencesAreVerified = verifiedReferences != nil
            let containerCount = records.compactMap { Int($0.containers) }.max()
            let unique = records.compactMap { parseSize($0.uniqueSize) }.max()
                ?? records.compactMap { parseSize($0.size) }.max()
                ?? 0
            let shared = records.compactMap { parseSize($0.sharedSize) }.max() ?? 0
            let virtual = records.compactMap { image in
                image.virtualSize.flatMap(parseSize) ?? parseSize(image.size)
            }.max() ?? 0
            let isDangling = referencesAreVerified && references.isEmpty
            let canRemove = referencesAreVerified && containerCount == 0
            let title = references.first ?? String(id.prefix(19))
            var detailParts = [
                "独占 \(formatBytes(unique))",
                "共享 \(formatBytes(shared))",
                "总大小 \(formatBytes(virtual))"
            ]
            if references.count > 1 { detailParts.append("\(references.count) 个仓库引用") }
            if let containerCount {
                detailParts.append("\(containerCount) 个容器")
            } else {
                detailParts.append("容器引用未知")
            }
            return StorageResourceNode(
                id: "docker.image.\(id)",
                kind: .dockerImage,
                title: title,
                detail: detailParts.joined(separator: " · "),
                symbol: "shippingbox.fill",
                allocatedBytes: unique,
                logicalBytes: virtual,
                entryCount: 1,
                risk: isDangling ? .rebuildableCache : .environmentOrRuntime,
                evidence: .providerReported,
                isProtected: !canRemove,
                cleanupTarget: canRemove ? .dockerImage(id: id) : nil
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
            let linkCount = Int(volume.links)
            let canRemove = linkCount == 0
            let detail: String
            if let linkCount {
                detail = linkCount > 0 ? "被 \(linkCount) 个容器引用" : "当前未被容器引用"
            } else {
                detail = "容器引用关系未知"
            }
            return StorageResourceNode(
                id: "docker.volume.\(volume.name)",
                kind: .dockerVolume,
                title: volume.name,
                detail: detail,
                symbol: "externaldrive.fill",
                allocatedBytes: bytes,
                logicalBytes: bytes,
                entryCount: 1,
                risk: .protectedUserData,
                evidence: .providerReported,
                isProtected: true,
                cleanupTarget: canRemove ? .dockerVolume(name: volume.name) : nil
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

    static func parseFallback(
        _ data: Data,
        imageReferencesByID: [String: [String]]? = nil
    ) throws -> [StorageResourceNode] {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DockerStorageInspectorError.malformedOutput
        }
        func records(_ key: String) -> [[String: Any]] {
            envelope[key] as? [[String: Any]] ?? []
        }
        func value(_ record: [String: Any], _ keys: String...) -> String {
            for key in keys {
                if let string = record[key] as? String, !string.isEmpty { return string }
                if let number = record[key] as? NSNumber { return number.stringValue }
            }
            return ""
        }

        let normalizedImages = records("Images").map { record -> [String: Any] in
            let id = value(record, "ID", "Id", "id")
            let repository = value(record, "Repository", "repository")
            let tag = value(record, "Tag", "tag")
            let size = value(record, "Size", "size")
            let containers = value(record, "Containers", "containers")
            return [
                "ID": id,
                "Repository": repository,
                "Tag": tag,
                "Containers": containers.isEmpty ? "0" : containers,
                "Size": size,
                "SharedSize": value(record, "SharedSize", "Shared", "shared"),
                "UniqueSize": value(record, "UniqueSize", "Unique", "unique").isEmpty
                    ? size
                    : value(record, "UniqueSize", "Unique", "unique"),
                "VirtualSize": value(record, "VirtualSize", "virtualSize", "size").isEmpty
                    ? size
                    : value(record, "VirtualSize", "virtualSize", "size")
            ]
        }
        let normalizedContainers = records("Containers").map { record -> [String: Any] in
            [
                "ID": value(record, "ID", "Id", "id"),
                "Names": value(record, "Names", "Name", "names", "name"),
                "Image": value(record, "Image", "image"),
                "State": value(record, "State", "state"),
                "Status": value(record, "Status", "status"),
                "Size": value(record, "Size", "size", "SizeRw")
            ]
        }
        let normalizedVolumes = records("Volumes").map { record -> [String: Any] in
            [
                "Name": value(record, "Name", "name"),
                "Links": value(record, "Links", "links"),
                "Size": value(record, "Size", "size")
            ]
        }
        let normalizedBuildCache = records("BuildCache").map { record -> [String: Any] in
            [
                "ID": value(record, "ID", "Id", "id"),
                "Description": value(record, "Description", "description"),
                "Size": value(record, "Size", "size"),
                "InUse": value(record, "InUse", "inUse")
                    .lowercased() == "true" ? "true" : "false",
                "LastUsedSince": value(record, "LastUsedSince", "lastUsedSince")
            ]
        }
        let inferredReferences = normalizedImages.reduce(into: [String: [String]]()) { result, image in
            guard let id = image["ID"] as? String, !id.isEmpty else { return }
            let repository = image["Repository"] as? String ?? ""
            let tag = image["Tag"] as? String ?? ""
            guard !repository.isEmpty, repository != "<none>" else {
                if result[id] == nil { result[id] = [] }
                return
            }
            result[id, default: []].append("\(repository):\(tag.isEmpty ? "latest" : tag)")
        }
        let normalized: [String: Any] = [
            "Images": normalizedImages,
            "Containers": normalizedContainers,
            "Volumes": normalizedVolumes,
            "BuildCache": normalizedBuildCache
        ]
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
        return try parse(
            normalizedData,
            imageReferencesByID: imageReferencesByID ?? inferredReferences
        )
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
        return try await ContainerCommandRunner().run(
            executableURL: executable,
            arguments: ["system", "df", "-v", "--format", "{{json .}}"],
            timeout: .seconds(12),
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
    }

    private static func runDockerObjectLists() async throws -> Data {
        guard let executable = dockerExecutable() else { throw DockerStorageInspectorError.unavailable }
        let runner = ContainerCommandRunner()
        async let images = runner.run(
            executableURL: executable,
            arguments: ["image", "ls", "--all", "--no-trunc", "--format", "{{json .}}"],
            timeout: .seconds(8),
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        async let containers = runner.run(
            executableURL: executable,
            arguments: ["container", "ls", "--all", "--size", "--no-trunc", "--format", "{{json .}}"],
            timeout: .seconds(8),
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        async let volumes = runner.run(
            executableURL: executable,
            arguments: ["volume", "ls", "--format", "{{json .}}"],
            timeout: .seconds(8),
            maximumOutputBytes: 4 * 1_024 * 1_024
        )
        return try makeFallbackEnvelope(
            images: await images,
            containers: await containers,
            volumes: await volumes
        )
    }

    static func makeFallbackEnvelope(
        images: Data,
        containers: Data,
        volumes: Data,
        buildCache: Data = Data("[]".utf8)
    ) throws -> Data {
        func records(_ data: Data) -> [[String: Any]] {
            if let value = try? JSONSerialization.jsonObject(with: data),
               let array = value as? [[String: Any]] {
                return array
            }
            if let value = try? JSONSerialization.jsonObject(with: data),
               let record = value as? [String: Any] {
                return [record]
            }
            return String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { line in
                    guard let lineData = String(line).data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                }
        }
        return try JSONSerialization.data(withJSONObject: [
            "Images": records(images),
            "Containers": records(containers),
            "Volumes": records(volumes),
            "BuildCache": records(buildCache)
        ])
    }

    private static func runDockerImageInspections() async throws -> [DockerImageInspection] {
        guard let executable = dockerExecutable() else { throw DockerStorageInspectorError.unavailable }
        let runner = ContainerCommandRunner()
        let idData = try await runner.run(
            executableURL: executable,
            arguments: ["image", "ls", "--all", "--quiet", "--no-trunc"],
            timeout: .seconds(8),
            maximumOutputBytes: 2 * 1_024 * 1_024
        )
        let ids = Set(
            String(decoding: idData, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        ).sorted()
        guard !ids.isEmpty else { return [] }

        var inspections: [DockerImageInspection] = []
        inspections.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: 128) {
            try Task.checkCancellation()
            let end = min(ids.count, start + 128)
            let data = try await runner.run(
                executableURL: executable,
                arguments: ["image", "inspect"] + ids[start..<end],
                timeout: .seconds(12),
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
            inspections.append(contentsOf: try JSONDecoder().decode(
                [DockerImageInspection].self,
                from: data
            ))
        }
        return inspections
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

struct PodmanStorageInspector: Sendable {
    typealias Runner = @Sendable () async throws -> Data
    private let runner: Runner
    private let fallbackRunner: Runner

    init(
        runner: @escaping Runner = PodmanStorageInspector.runSystemDF,
        fallbackRunner: @escaping Runner = PodmanStorageInspector.runObjectLists
    ) {
        self.runner = runner
        self.fallbackRunner = fallbackRunner
    }

    func inspect() async -> DockerStorageInventory {
        if let data = try? await runner(),
           let nodes = try? DockerStorageInspector.parse(data) {
            return DockerStorageInventory(nodes: nodes, diagnostic: nil)
        }
        guard let fallbackData = try? await fallbackRunner(),
              let nodes = try? DockerStorageInspector.parseFallback(fallbackData) else {
            return DockerStorageInventory(
                nodes: [],
                diagnostic: "Podman Engine inventory unavailable"
            )
        }
        return DockerStorageInventory(
            nodes: nodes,
            diagnostic: "Podman 容量报告不可用，已使用对象清单"
        )
    }

    private static func runSystemDF() async throws -> Data {
        guard let executable = podmanExecutable() else {
            throw DockerStorageInspectorError.unavailable
        }
        return try await ContainerCommandRunner().run(
            executableURL: executable,
            arguments: ["system", "df", "-v", "--format", "json"],
            timeout: .seconds(12),
            maximumOutputBytes: 16 * 1_024 * 1_024
        )
    }

    private static func runObjectLists() async throws -> Data {
        guard let executable = podmanExecutable() else {
            throw DockerStorageInspectorError.unavailable
        }
        let runner = ContainerCommandRunner()
        async let images = runner.run(
            executableURL: executable,
            arguments: ["images", "--all", "--no-trunc", "--format", "json"],
            timeout: .seconds(8),
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        async let containers = runner.run(
            executableURL: executable,
            arguments: ["ps", "--all", "--size", "--no-trunc", "--format", "json"],
            timeout: .seconds(8),
            maximumOutputBytes: 8 * 1_024 * 1_024
        )
        async let volumes = runner.run(
            executableURL: executable,
            arguments: ["volume", "ls", "--format", "json"],
            timeout: .seconds(8),
            maximumOutputBytes: 4 * 1_024 * 1_024
        )
        return try DockerStorageInspector.makeFallbackEnvelope(
            images: await images,
            containers: await containers,
            volumes: await volumes
        )
    }

    private static func podmanExecutable() -> URL? {
        [
            "/opt/homebrew/bin/podman",
            "/usr/local/bin/podman",
            "/Applications/Podman Desktop.app/Contents/Resources/bin/podman"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }
}

struct DockerImageInspection: Decodable, Sendable {
    let id: String
    let repoTags: [String]?
    let repoDigests: [String]?

    var references: [String] {
        Set((repoTags ?? []) + (repoDigests ?? []))
            .filter { !$0.isEmpty && $0 != "<none>:<none>" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case repoDigests = "RepoDigests"
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
    let virtualSize: String?

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

actor ContainerCommandRunner {
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

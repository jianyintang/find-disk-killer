import Darwin
import Foundation

public enum AgentDataLocationDiscoveryKind: String, Codable, Hashable, Sendable {
    case officialDefault
    case environmentVariable
    case knownClient
    case userAdded
    case embeddedAgent
}

public enum AgentDataLocationAvailability: String, Codable, Hashable, Sendable {
    case readable
    case unreadable
}

public struct AgentDataLocationIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct AgentDataLocationOrigin: Codable, Hashable, Sendable {
    public let kind: AgentDataLocationDiscoveryKind
    public let identifier: String?
    public let configuredPath: String

    public init(
        kind: AgentDataLocationDiscoveryKind,
        identifier: String? = nil,
        configuredPath: String
    ) {
        self.kind = kind
        self.identifier = identifier
        self.configuredPath = configuredPath
    }
}

public struct AgentDataLocation: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let provider: AgentStorageProvider
    public let kind: AgentStorageSourceKind
    public let displayName: String
    public let configuredPath: String
    public let resolvedPath: String
    public let origins: [AgentDataLocationOrigin]
    public let availability: AgentDataLocationAvailability
    public let identity: AgentDataLocationIdentity
    public let volumeID: String?
    public let volumeName: String?
    public let volumeMountPath: String?

    public init(
        id: String,
        provider: AgentStorageProvider,
        kind: AgentStorageSourceKind,
        displayName: String,
        configuredPath: String,
        resolvedPath: String,
        origins: [AgentDataLocationOrigin],
        availability: AgentDataLocationAvailability,
        identity: AgentDataLocationIdentity,
        volumeID: String?,
        volumeName: String?,
        volumeMountPath: String?
    ) {
        self.id = id
        self.provider = provider
        self.kind = kind
        self.displayName = displayName
        self.configuredPath = configuredPath
        self.resolvedPath = resolvedPath
        self.origins = origins
        self.availability = availability
        self.identity = identity
        self.volumeID = volumeID
        self.volumeName = volumeName
        self.volumeMountPath = volumeMountPath
    }
}

public struct AgentDataLocationDiscovery {
    public struct Configuration: Sendable {
        public let homeDirectory: URL
        public let additionalRoots: [URL]
        public let includesDesktopData: Bool
        public let environment: [String: String]
        let mountedVolumes: [VolumeInfo]?

        public init(
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool = true,
            environment: [String: String]? = nil
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            self.environment = environment ?? Self.defaultEnvironment(for: homeDirectory)
            mountedVolumes = nil
        }

        init(
            homeDirectory: URL,
            additionalRoots: [URL] = [],
            includesDesktopData: Bool = true,
            environment: [String: String] = [:],
            mountedVolumes: [VolumeInfo]
        ) {
            self.homeDirectory = homeDirectory
            self.additionalRoots = additionalRoots
            self.includesDesktopData = includesDesktopData
            self.environment = environment
            self.mountedVolumes = mountedVolumes
        }

        private static func defaultEnvironment(for homeDirectory: URL) -> [String: String] {
            let requested = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let current = FileManager.default.homeDirectoryForCurrentUser
                .resolvingSymlinksInPath().standardizedFileURL.path
            return requested == current ? ProcessInfo.processInfo.environment : [:]
        }
    }

    private struct Candidate: Sendable {
        let id: String
        let provider: AgentStorageProvider
        let kind: AgentStorageSourceKind
        let displayName: String
        let url: URL
        let discoveryKind: AgentDataLocationDiscoveryKind
        let discoveryIdentifier: String?
    }

    private struct LocatedCandidate: Sendable {
        let candidate: Candidate
        let configuredPath: String
        let resolvedPath: String
        let availability: AgentDataLocationAvailability
        let identity: AgentDataLocationIdentity
        let volume: VolumeInfo?
    }

    private let configuration: Configuration
    private let fileManager: FileManager

    public init(
        configuration: Configuration = .init(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func discover() -> [AgentDataLocation] {
        let home = configuration.homeDirectory.standardizedFileURL
        let volumes = configuration.mountedVolumes ?? Self.collectMountedVolumes()
        var candidates = defaultCandidates(home: home)
        candidates.append(contentsOf: environmentCandidates(home: home))
        if configuration.includesDesktopData {
            candidates.append(contentsOf: desktopCandidates(home: home))
        }
        candidates.append(contentsOf: customCandidates())

        let desktopRoots = candidates.filter {
            $0.kind == .claudeDesktop && fileManager.fileExists(atPath: $0.url.path)
        }
        for desktopRoot in desktopRoots {
            candidates.append(contentsOf: nestedClaudeCandidates(in: desktopRoot.url))
        }

        let located = candidates.compactMap { locate($0, volumes: volumes) }
        let grouped = Dictionary(grouping: located) {
            PhysicalKey(provider: $0.candidate.provider, identity: $0.identity)
        }
        return grouped.values.compactMap(makeLocation).sorted {
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.resolvedPath.localizedStandardCompare($1.resolvedPath) == .orderedAscending
        }
    }

    public static func recognizedProvider(at url: URL) -> AgentStorageProvider? {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        if fileManager.fileExists(atPath: resolved.appending(path: "state_5.sqlite").path)
            || fileManager.fileExists(atPath: resolved.appending(path: "sessions").path) {
            return .codex
        }
        if fileManager.fileExists(atPath: resolved.appending(path: "projects").path) {
            return .claude
        }
        if fileManager.fileExists(atPath: resolved.appending(path: "opencode.db").path) {
            return .openCode
        }
        return nil
    }

    private func defaultCandidates(home: URL) -> [Candidate] {
        [
            candidate("codex.home", .codex, .codexHome, "Codex CLI", home.appending(path: ".codex"), .officialDefault),
            candidate("codex.cc-home", .codex, .codexHome, "Codex CC", home.appending(path: ".codex-cc"), .knownClient, "codex-cc"),
            candidate("claude.code", .claude, .claudeCode, "Claude Code", home.appending(path: ".claude"), .officialDefault),
            candidate("openCode.data", .openCode, .openCode, "OpenCode", home.appending(path: ".local/share/opencode"), .officialDefault)
        ]
    }

    private func environmentCandidates(home: URL) -> [Candidate] {
        var result: [Candidate] = []
        if let url = environmentURL(named: "CODEX_HOME", home: home) {
            result.append(candidate(
                "codex.environment.CODEX_HOME", .codex, .codexHome, "Codex CLI",
                url, .environmentVariable, "CODEX_HOME"
            ))
        }
        if let url = environmentURL(named: "CLAUDE_CONFIG_DIR", home: home) {
            result.append(candidate(
                "claude.environment.CLAUDE_CONFIG_DIR", .claude, .claudeCode, "Claude Code",
                url, .environmentVariable, "CLAUDE_CONFIG_DIR"
            ))
        }
        if let dataHome = environmentURL(named: "XDG_DATA_HOME", home: home) {
            result.append(candidate(
                "openCode.environment.XDG_DATA_HOME", .openCode, .openCode, "OpenCode",
                dataHome.appending(path: "opencode"), .environmentVariable, "XDG_DATA_HOME"
            ))
        }
        return result
    }

    private func desktopCandidates(home: URL) -> [Candidate] {
        let support = home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return [
            candidate("codex.desktop", .codex, .codexDesktop, "Codex Desktop", support.appending(path: "Codex"), .knownClient, "Codex"),
            candidate("codex.desktop.bundle", .codex, .codexDesktop, "Codex Desktop", support.appending(path: "com.openai.codex"), .knownClient, "com.openai.codex"),
            candidate("codex.desktop.chat", .codex, .codexDesktop, "Codex Desktop", support.appending(path: "com.openai.chat"), .knownClient, "com.openai.chat"),
            candidate("claude.desktop-3p", .claude, .claudeDesktop, "Claude Desktop", support.appending(path: "Claude-3p"), .knownClient, "Claude-3p"),
            candidate("claude.desktop", .claude, .claudeDesktop, "Claude Desktop", support.appending(path: "Claude"), .knownClient, "Claude")
        ]
    }

    private func customCandidates() -> [Candidate] {
        configuration.additionalRoots.compactMap { url in
            guard let provider = Self.recognizedProvider(at: url) else { return nil }
            let kind: AgentStorageSourceKind
            let displayName: String
            switch provider {
            case .codex:
                kind = .codexHome
                displayName = "Codex CLI"
            case .claude:
                kind = .claudeCode
                displayName = "Claude Code"
            case .openCode:
                kind = .openCode
                displayName = "OpenCode"
            }
            let configured = configuredURL(url).path
            return candidate(
                "\(provider.rawValue).custom.\(stablePathHash(configured))",
                provider,
                kind,
                displayName,
                url,
                .userAdded,
                nil
            )
        }
    }

    private func nestedClaudeCandidates(in desktopRoot: URL) -> [Candidate] {
        let sessionsRoot = desktopRoot.appending(path: "local-agent-mode-sessions", directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: sessionsRoot.path),
              let enumerator = fileManager.enumerator(
                at: sessionsRoot,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, _ in true }
              ) else { return [] }
        var result: [Candidate] = []
        for case let url as URL in enumerator {
            var value = stat()
            guard lstat(url.path, &value) == 0 else { continue }
            let type = value.st_mode & S_IFMT
            if type == S_IFLNK {
                enumerator.skipDescendants()
                continue
            }
            guard type == S_IFDIR, url.lastPathComponent == ".claude" else { continue }
            guard fileManager.fileExists(atPath: url.appending(path: "projects").path) else {
                enumerator.skipDescendants()
                continue
            }
            result.append(candidate(
                "claude.embedded.\(stablePathHash(url.path))",
                .claude,
                .claudeDesktopAgent,
                "Claude Desktop Agent",
                url,
                .embeddedAgent,
                desktopRoot.lastPathComponent
            ))
            enumerator.skipDescendants()
        }
        return result
    }

    private func locate(_ candidate: Candidate, volumes: [VolumeInfo]) -> LocatedCandidate? {
        let configured = configuredURL(candidate.url)
        guard fileManager.fileExists(atPath: configured.path) else { return nil }
        let resolved = canonicalURL(configured)
        var value = stat()
        guard stat(resolved.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let identity = AgentDataLocationIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino)
        )
        return LocatedCandidate(
            candidate: candidate,
            configuredPath: configured.path,
            resolvedPath: resolved.path,
            availability: fileManager.isReadableFile(atPath: resolved.path) ? .readable : .unreadable,
            identity: identity,
            volume: VolumePathResolver.bestMatch(for: resolved.path, in: volumes)
        )
    }

    private func makeLocation(_ matches: [LocatedCandidate]) -> AgentDataLocation? {
        guard let primary = matches.min(by: { candidateOrder($0.candidate) < candidateOrder($1.candidate) }) else {
            return nil
        }
        let origins = matches.map {
            AgentDataLocationOrigin(
                kind: $0.candidate.discoveryKind,
                identifier: $0.candidate.discoveryIdentifier,
                configuredPath: $0.configuredPath
            )
        }.uniqued().sorted {
            if originOrder($0.kind) != originOrder($1.kind) {
                return originOrder($0.kind) < originOrder($1.kind)
            }
            return $0.configuredPath < $1.configuredPath
        }
        return AgentDataLocation(
            id: primary.candidate.id,
            provider: primary.candidate.provider,
            kind: primary.candidate.kind,
            displayName: primary.candidate.displayName,
            configuredPath: primary.configuredPath,
            resolvedPath: primary.resolvedPath,
            origins: origins,
            availability: matches.contains(where: { $0.availability == .readable }) ? .readable : .unreadable,
            identity: primary.identity,
            volumeID: primary.volume?.id,
            volumeName: primary.volume?.name,
            volumeMountPath: primary.volume?.mountPath
        )
    }

    private func candidate(
        _ id: String,
        _ provider: AgentStorageProvider,
        _ kind: AgentStorageSourceKind,
        _ displayName: String,
        _ url: URL,
        _ discoveryKind: AgentDataLocationDiscoveryKind,
        _ discoveryIdentifier: String? = nil
    ) -> Candidate {
        Candidate(
            id: id,
            provider: provider,
            kind: kind,
            displayName: displayName,
            url: url,
            discoveryKind: discoveryKind,
            discoveryIdentifier: discoveryIdentifier
        )
    }

    private func environmentURL(named name: String, home: URL) -> URL? {
        guard let raw = configuration.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return home.appending(path: expanded, directoryHint: .isDirectory).standardizedFileURL
    }

    private func configuredURL(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
    }

    private func canonicalURL(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<terminator].map { UInt8(bitPattern: $0) }
        return URL(
            fileURLWithPath: String(decoding: bytes, as: UTF8.self),
            isDirectory: true
        )
    }

    private func candidateOrder(_ candidate: Candidate) -> (Int, String) {
        (originOrder(candidate.discoveryKind), candidate.url.path)
    }

    private func originOrder(_ kind: AgentDataLocationDiscoveryKind) -> Int {
        switch kind {
        case .officialDefault: 0
        case .environmentVariable: 1
        case .knownClient: 2
        case .embeddedAgent: 3
        case .userAdded: 4
        }
    }

    static func collectMountedVolumes() -> [VolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey, .volumeIdentifierKey
        ]
        return (FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []).compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.volumeIsLocal == true,
                  values?.volumeIsReadOnly == false,
                  let total = values?.volumeTotalCapacity,
                  total > 0 else { return nil }
            let identifier = values?.volumeUUIDString
                ?? values?.volumeIdentifier.map { String(describing: $0) }
                ?? "mount:\(url.standardizedFileURL.path)"
            let fallbackName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return VolumeInfo(
                id: identifier,
                name: values?.volumeName ?? fallbackName,
                mountPath: url.standardizedFileURL.path,
                totalCapacity: Int64(total),
                availableCapacity: Int64(values?.volumeAvailableCapacity ?? 0),
                isLocal: true,
                isWritable: true,
                hasStableIdentity: values?.volumeUUIDString != nil || values?.volumeIdentifier != nil,
                isRemovable: false,
                physicalDiskBSDNames: []
            )
        }
    }
}

private struct PhysicalKey: Hashable {
    let provider: AgentStorageProvider
    let identity: AgentDataLocationIdentity
}

private func stablePathHash(_ path: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in path.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

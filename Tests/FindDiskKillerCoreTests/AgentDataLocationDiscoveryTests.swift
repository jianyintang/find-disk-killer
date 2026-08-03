import Darwin
import Foundation
import Testing
@testable import FindDiskKillerCore

@Suite("Agent data location discovery")
struct AgentDataLocationDiscoveryTests {
    @Test func defaultAndEnvironmentCodexHomesAreBothDiscovered() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let defaultHome = try fixture.directory("home/.codex")
        let configuredHome = try fixture.directory("configured-codex")
        try fixture.file("home/.codex/state_5.sqlite")
        try fixture.file("configured-codex/state_5.sqlite")

        let locations = fixture.discovery(environment: ["CODEX_HOME": configuredHome.path]).discover()
        let codex = locations.filter { $0.provider == .codex && $0.kind == .codexHome }

        #expect(Set(codex.map(\.resolvedPath)) == Set([
            fixture.canonicalPath(defaultHome), fixture.canonicalPath(configuredHome)
        ]))
        #expect(codex.contains { location in
            location.origins.contains {
                $0.kind == .environmentVariable && $0.identifier == "CODEX_HOME"
            }
        })
    }

    @Test func logicalAliasesOfOnePhysicalDirectoryAreNotDuplicated() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let target = try fixture.directory("external/codex")
        try fixture.file("external/codex/state_5.sqlite")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".codex"),
            withDestinationURL: target
        )
        let alias = fixture.root.appending(path: "codex-environment")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let codex = fixture.discovery(environment: ["CODEX_HOME": alias.path])
            .discover()
            .filter { $0.provider == .codex && $0.kind == .codexHome }

        #expect(codex.count == 1)
        #expect(codex[0].resolvedPath == fixture.canonicalPath(target))
        #expect(Set(codex[0].origins.map(\.configuredPath)) == Set([
            fixture.home.appending(path: ".codex").path,
            alias.path
        ]))
    }

    @Test func codexHomeCachesAreSeparateForDefaultEnvironmentAndCustomHomes() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let defaultCache = try fixture.directory("home/.codex/cache")
        let configuredTmp = try fixture.directory("configured-codex/tmp")
        let customHiddenTmp = try fixture.directory("custom/codex/.tmp")
        try fixture.file("home/.codex/state_5.sqlite")
        try fixture.file("configured-codex/state_5.sqlite")
        try fixture.file("custom/codex/state_5.sqlite")

        let locations = AgentDataLocationDiscovery(configuration: .init(
            homeDirectory: fixture.home,
            additionalRoots: [customHiddenTmp.deletingLastPathComponent()],
            includesDesktopData: false,
            environment: ["CODEX_HOME": configuredTmp.deletingLastPathComponent().path],
            mountedVolumes: [fixture.systemVolume, fixture.externalVolume]
        )).discover()
        let cachePaths = Set(locations.filter {
            $0.provider == .codex && $0.kind == .rebuildableCache
        }.map(\.resolvedPath))

        #expect(cachePaths == Set([
            fixture.canonicalPath(defaultCache),
            fixture.canonicalPath(configuredTmp),
            fixture.canonicalPath(customHiddenTmp)
        ]))
    }

    @Test func standardMacOSCachesAreDiscoveredWithoutProtectedBrowserState() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let codexCache = try fixture.directory("home/Library/Caches/Codex")
        let codexCodeCache = try fixture.directory(
            "home/Library/Application Support/Codex/Default/Code Cache"
        )
        let claudeGPUCache = try fixture.directory(
            "home/Library/Application Support/Claude/GPUCache"
        )
        let claudeCLICache = try fixture.directory("home/Library/Caches/claude-cli-nodejs")
        _ = try fixture.directory("home/Library/Application Support/Codex/Partitions")
        _ = try fixture.directory("home/Library/Application Support/Claude/IndexedDB")

        let locations = AgentDataLocationDiscovery(configuration: .init(
            homeDirectory: fixture.home,
            includesDesktopData: true,
            environment: [:],
            mountedVolumes: [fixture.systemVolume]
        )).discover()
        let cachePaths = Set(locations.filter { $0.kind == .rebuildableCache }.map(\.resolvedPath))

        #expect(cachePaths == Set([
            fixture.canonicalPath(codexCache),
            fixture.canonicalPath(codexCodeCache),
            fixture.canonicalPath(claudeGPUCache),
            fixture.canonicalPath(claudeCLICache)
        ]))
        #expect(!cachePaths.contains { $0.hasSuffix("/Partitions") || $0.hasSuffix("/IndexedDB") })
    }

    @Test func cacheAliasesAreDeduplicatedByPhysicalIdentity() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let target = try fixture.directory("external/codex/cache")
        try fixture.file("external/codex/state_5.sqlite")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".codex"),
            withDestinationURL: target.deletingLastPathComponent()
        )
        let alias = fixture.root.appending(path: "codex-environment")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: target.deletingLastPathComponent()
        )

        let caches = fixture.discovery(environment: ["CODEX_HOME": alias.path])
            .discover()
            .filter { $0.provider == .codex && $0.kind == .rebuildableCache }

        #expect(caches.count == 1)
        #expect(caches[0].resolvedPath == fixture.canonicalPath(target))
    }

    @Test func symlinkedCodexCCIsAttributedToItsResolvedExternalVolume() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let target = try fixture.directory("external/.codex-cc")
        try fixture.file("external/.codex-cc/state_5.sqlite")
        try FileManager.default.createSymbolicLink(
            at: fixture.home.appending(path: ".codex-cc"),
            withDestinationURL: target
        )

        let locations = fixture.discovery(
            mountedVolumes: [fixture.systemVolume, fixture.externalVolume]
        ).discover()
        let codexCC = try #require(locations.first { $0.id == "codex.cc-home" })

        #expect(codexCC.configuredPath == fixture.home.appending(path: ".codex-cc").path)
        #expect(codexCC.resolvedPath == fixture.canonicalPath(target))
        #expect(codexCC.volumeID == fixture.externalVolume.id)
        #expect(codexCC.volumeName == fixture.externalVolume.name)
    }

    @Test func customCodexClaudeAndOpenCodeLocationsAreRecognized() throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        let codex = try fixture.directory("custom/codex")
        let claude = try fixture.directory("custom/claude/projects")
        let openCode = try fixture.directory("custom/opencode")
        try fixture.file("custom/codex/state_5.sqlite")
        try fixture.file("custom/opencode/opencode.db")

        let locations = AgentDataLocationDiscovery(configuration: .init(
            homeDirectory: fixture.home,
            additionalRoots: [codex, claude.deletingLastPathComponent(), openCode],
            includesDesktopData: false,
            environment: [:],
            mountedVolumes: [fixture.systemVolume]
        )).discover()

        #expect(Set(locations.map(\.provider)) == Set(AgentStorageProvider.allCases))
        #expect(locations.allSatisfy { location in
            location.origins.contains { $0.kind == .userAdded }
        })
    }

    @Test func storageCatalogAndDeepScannerConsumeTheSameLocationSet() async throws {
        let fixture = try AgentLocationFixture()
        defer { fixture.remove() }
        _ = try fixture.directory("home/.codex/sessions")
        try fixture.file("home/.codex/state_5.sqlite")
        _ = try fixture.directory("home/.claude/projects")
        let openCode = try fixture.directory("home/.local/share/opencode")
        try fixture.file("home/.local/share/opencode/opencode.db")

        let locations = fixture.discovery().discover()
        let storageCandidates = StorageSourceCatalog.detect(configuration: .init(
            homeDirectory: fixture.home,
            agentDataLocations: locations,
            environment: [:]
        ))
        let storageIDs = Set(storageCandidates
            .filter { $0.id.agentProvider != nil }
            .flatMap(\.roots)
            .map(\.id))
        let snapshot = try await AgentStorageScanner(configuration: .init(
            homeDirectory: fixture.home,
            includesDesktopData: false,
            agentDataLocations: locations,
            environment: [:]
        )).scan()

        #expect(storageIDs == Set(locations.map(\.id)))
        #expect(Set(snapshot.sources.map(\.id)) == Set(locations.map(\.id)))
        #expect(snapshot.sources.first {
            $0.resolvedPath == fixture.canonicalPath(openCode)
        }?.volumeID != nil)
    }
}

private extension StorageSourceID {
    var agentProvider: AgentStorageProvider? {
        if self == .codex { return .codex }
        if self == .claude { return .claude }
        if self == .openCode { return .openCode }
        return nil
    }
}

private final class AgentLocationFixture {
    let root: URL
    let home: URL
    let external: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "AgentLocationFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        external = root.appending(path: "external", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
    }

    var systemVolume: VolumeInfo {
        VolumeInfo(
            id: "system",
            name: "System",
            mountPath: canonicalPath(home),
            totalCapacity: 1_000_000_000,
            availableCapacity: 500_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: false,
            physicalDiskBSDNames: []
        )
    }

    var externalVolume: VolumeInfo {
        VolumeInfo(
            id: "external",
            name: "External",
            mountPath: canonicalPath(external),
            totalCapacity: 2_000_000_000,
            availableCapacity: 1_500_000_000,
            isLocal: true,
            isWritable: true,
            hasStableIdentity: true,
            isRemovable: true,
            physicalDiskBSDNames: []
        )
    }

    func discovery(
        environment: [String: String] = [:],
        mountedVolumes: [VolumeInfo]? = nil
    ) -> AgentDataLocationDiscovery {
        AgentDataLocationDiscovery(configuration: .init(
            homeDirectory: home,
            includesDesktopData: false,
            environment: environment,
            mountedVolumes: mountedVolumes ?? [systemVolume, externalVolume]
        ))
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ path: String) throws {
        let url = root.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func canonicalPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL.path }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

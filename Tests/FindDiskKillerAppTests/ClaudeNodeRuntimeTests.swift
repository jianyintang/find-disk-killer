import Foundation
import Testing
@testable import FindDiskKillerApp

@Suite("Claude Node runtime resolution")
struct ClaudeNodeRuntimeTests {
    @Test func versionGateAcceptsSupportedMajorsOnly() {
        #expect(ClaudeNodeRuntime.isCompatibleVersion("v24.14.1\n"))
        #expect(ClaudeNodeRuntime.isCompatibleVersion("v20.0.0"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("v18.20.4"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("24.14.1"))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion(""))
        #expect(!ClaudeNodeRuntime.isCompatibleVersion("version unknown"))
    }

    @Test func downloadTargetsMatchPinnedOfficialBuilds() {
        #expect(ClaudeNodeRuntime.downloadURL(for: .arm64).absoluteString
            == "https://nodejs.org/dist/v24.14.1/node-v24.14.1-darwin-arm64.tar.gz")
        #expect(ClaudeNodeRuntime.downloadURL(for: .x64).absoluteString
            == "https://nodejs.org/dist/v24.14.1/node-v24.14.1-darwin-x64.tar.gz")
        for architecture in ClaudeNodeRuntime.Architecture.allCases {
            let digest = architecture.expectedSHA256
            #expect(digest.count == 64)
            #expect(digest.allSatisfy(\.isHexDigit))
        }
    }

    @Test func environmentOverrideWinsOverEveryOtherCandidate() {
        let resolved = ClaudeNodeRuntime.existingRuntime(
            environment: ["FDK_NODE_BINARY": "/tmp/override-node", "PATH": "/tmp/path-bin"],
            bundledRuntimePath: "/tmp/bundled-node",
            applicationSupport: URL(fileURLWithPath: "/tmp/support"),
            isExecutable: { _ in true },
            versionOutput: { _ in "v24.14.1" }
        )
        #expect(resolved == "/tmp/override-node")
    }

    @Test func downloadedRuntimeIsPreferredOverPathInstallations() {
        let support = URL(fileURLWithPath: "/tmp/support")
        let downloaded = ClaudeNodeRuntime.downloadedBinaryURL(
            for: ClaudeNodeRuntime.currentArchitecture(),
            applicationSupport: support
        ).path
        let resolved = ClaudeNodeRuntime.existingRuntime(
            environment: ["PATH": "/tmp/path-bin"],
            bundledRuntimePath: nil,
            applicationSupport: support,
            isExecutable: { $0 == downloaded || $0 == "/tmp/path-bin/node" },
            versionOutput: { _ in "v24.14.1" }
        )
        #expect(resolved == downloaded)
    }

    @Test func pathRuntimeRequiresCompatibleVersion() {
        let outdatedOnly = ClaudeNodeRuntime.existingRuntime(
            environment: ["PATH": "/tmp/old-bin"],
            bundledRuntimePath: nil,
            applicationSupport: URL(fileURLWithPath: "/tmp/support"),
            isExecutable: { $0 == "/tmp/old-bin/node" },
            versionOutput: { _ in "v18.19.0" }
        )
        #expect(outdatedOnly == nil)

        let modern = ClaudeNodeRuntime.existingRuntime(
            environment: ["PATH": "/tmp/old-bin:/tmp/new-bin"],
            bundledRuntimePath: nil,
            applicationSupport: URL(fileURLWithPath: "/tmp/support"),
            isExecutable: { $0 == "/tmp/old-bin/node" || $0 == "/tmp/new-bin/node" },
            versionOutput: { $0 == "/tmp/new-bin/node" ? "v22.11.0" : "v16.20.0" }
        )
        #expect(modern == "/tmp/new-bin/node")
    }

    @Test func missingRuntimeResolvesToNilInsteadOfGuessing() {
        let resolved = ClaudeNodeRuntime.existingRuntime(
            environment: ["PATH": "/tmp/path-bin"],
            bundledRuntimePath: "/tmp/bundled-node",
            applicationSupport: URL(fileURLWithPath: "/tmp/support"),
            isExecutable: { _ in false },
            versionOutput: { _ in nil }
        )
        #expect(resolved == nil)
    }

    @Test func downloadedBinaryLivesUnderApplicationSupport() {
        let support = URL(fileURLWithPath: "/Users/example/Library/Application Support/FindDiskKiller")
        let path = ClaudeNodeRuntime.downloadedBinaryURL(for: .arm64, applicationSupport: support).path
        #expect(path == "/Users/example/Library/Application Support/FindDiskKiller/AgentCleanup/node-v24.14.1-arm64/node")
    }

    @Test func statusSourceClassificationCoversEveryOrigin() {
        let downloadRoot = "/Users/example/Library/Application Support/FindDiskKiller/AgentCleanup"
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: "/tmp/override-node",
            environmentOverride: "/tmp/override-node",
            bundledPath: "/Applications/App.app/Contents/Resources/AgentCleanup/node",
            downloadRoot: downloadRoot
        ) == .environmentOverride)
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: "/Applications/App.app/Contents/Resources/AgentCleanup/node",
            environmentOverride: nil,
            bundledPath: "/Applications/App.app/Contents/Resources/AgentCleanup/node",
            downloadRoot: downloadRoot
        ) == .legacyBundled)
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: downloadRoot + "/node-v24.14.1-arm64/node",
            environmentOverride: nil,
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .downloaded)
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: "/opt/homebrew/bin/node",
            environmentOverride: nil,
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .system)
    }

    @Test func statusSourceClassificationDoesNotMatchSiblingDirectories() {
        let downloadRoot = "/Users/example/Library/Application Support/FindDiskKiller/AgentCleanup"
        #expect(ClaudeNodeRuntimeStatusModel.classify(
            path: downloadRoot + "Backup/node",
            environmentOverride: nil,
            bundledPath: nil,
            downloadRoot: downloadRoot
        ) == .system)
    }
}

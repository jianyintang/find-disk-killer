import Foundation
import FindDiskKillerNodeRuntime

let environment = ProcessInfo.processInfo.environment
let fileManager = FileManager.default
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let resources = executable
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Resources/AgentCleanup", directoryHint: .isDirectory)
let script = resources.appending(path: "claude-cleanup-helper.mjs")

guard let requestedNode = environment["FDK_NODE_BINARY"] else {
    FileHandle.standardError.write(Data("FDK_NODE_BINARY is required; launch this helper through FindDiskKiller\n".utf8))
    exit(69)
}

let node: String
do {
    node = try NodeRuntimeResolver.validate(
        path: requestedNode,
        source: .environmentOverride,
        minimumMajor: 20
    ).path
} catch {
    FileHandle.standardError.write(Data("FDK_NODE_BINARY is invalid: \(error)\n".utf8))
    exit(69)
}

guard fileManager.fileExists(atPath: script.path) else {
    FileHandle.standardError.write(Data("Bundled Claude SDK script is unavailable\n".utf8))
    exit(69)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: node)
// The helper performs short-lived SDK file operations and does not benefit from
// JIT compilation. Disabling it avoids reserving V8's large executable code
// range on memory-constrained Macs.
process.arguments = ["--jitless", script.path]
process.standardInput = FileHandle.standardInput
process.standardOutput = FileHandle.standardOutput
process.standardError = FileHandle.standardError

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("Failed to start bundled Claude SDK: \(error)\n".utf8))
    exit(70)
}

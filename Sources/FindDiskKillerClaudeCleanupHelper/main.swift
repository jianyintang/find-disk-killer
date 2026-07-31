import Foundation

let environment = ProcessInfo.processInfo.environment
let fileManager = FileManager.default
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let resources = executable
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Resources/AgentCleanup", directoryHint: .isDirectory)
let script = resources.appending(path: "claude-cleanup-helper.mjs")

let isExecutable: (String) -> Bool = { fileManager.isExecutableFile(atPath: $0) }

// Mirrors the resolution order of ClaudeNodeRuntime in the main app: explicit
// override, legacy bundled runtime, a runtime downloaded by the app into
// Application Support, then any installation reachable from PATH or common
// package-manager locations. The app normally resolves the runtime first and
// passes it via FDK_NODE_BINARY; the fallbacks keep direct helper invocations
// (fixtures, development) working.
let resolveNodeBinary: () -> String? = {
    if let override = environment["FDK_NODE_BINARY"], isExecutable(override) {
        return override
    }
    let bundled = resources.appending(path: "node").path
    if isExecutable(bundled) { return bundled }

    let supportRoot = (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser.appending(path: "Library/Application Support"))
        .appending(path: "FindDiskKiller/AgentCleanup", directoryHint: .isDirectory)
    let downloaded = ((try? fileManager.contentsOfDirectory(atPath: supportRoot.path)) ?? [])
        .sorted(by: >)
        .map { supportRoot.appending(path: "\($0)/node").path }
        .first(where: isExecutable)
    if let downloaded { return downloaded }

    let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let commonDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    return (pathDirectories + commonDirectories)
        .map { URL(fileURLWithPath: $0).appending(path: "node").path }
        .first(where: isExecutable)
}

guard let node = resolveNodeBinary(), fileManager.fileExists(atPath: script.path) else {
    FileHandle.standardError.write(Data("Bundled Claude SDK runtime is unavailable\n".utf8))
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

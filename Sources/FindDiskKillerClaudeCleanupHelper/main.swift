import Foundation

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let resources = executable
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Resources/AgentCleanup", directoryHint: .isDirectory)
let node = resources.appending(path: "node")
let script = resources.appending(path: "claude-cleanup-helper.mjs")

guard FileManager.default.isExecutableFile(atPath: node.path),
      FileManager.default.fileExists(atPath: script.path) else {
    FileHandle.standardError.write(Data("Bundled Claude SDK runtime is unavailable\n".utf8))
    exit(69)
}

let process = Process()
process.executableURL = node
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

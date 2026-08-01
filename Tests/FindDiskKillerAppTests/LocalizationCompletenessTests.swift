import Foundation
import Testing
@testable import FindDiskKillerApp

@Test func recentlyAddedSettingsCopyHasAnEnglishTranslation() {
    #expect(L10n.text("自动（%@）", language: .english) == "Automatic (%@)")
    #expect(
        L10n.text("压缩后约 %@ – %@", language: .english)
            == "Approximately %@ – %@ after compression"
    )
}

@Test func appChineseStringLiteralsResolveWithoutChineseInEnglish() throws {
    let appSources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp", isDirectory: true)
    let files = try swiftFiles(in: appSources)
        .filter { $0.lastPathComponent != "Localization.swift" }
    var unresolved: [String] = []

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for literal in swiftStringLiterals(in: source) where literal.containsCJKUnifiedIdeograph {
            let english = L10n.text(literal, language: .english)
            if english.containsCJKUnifiedIdeograph {
                let relativePath = file.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
                unresolved.append("\(relativePath): \(literal)")
            }
        }
    }

    #expect(
        unresolved.isEmpty,
        "Chinese UI literals without an English resolution:\n\(unresolved.sorted().joined(separator: "\n"))"
    )
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func swiftFiles(in root: URL) throws -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw CocoaError(.fileReadUnknown)
    }
    return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
        return url
    }
}

private func swiftStringLiterals(in source: String) -> [String] {
    let expression = try! NSRegularExpression(pattern: #"(?<!#)"((?:\\.|[^"\\])*)""#)
    let range = NSRange(source.startIndex..., in: source)
    return expression.matches(in: source, range: range).compactMap { match in
        guard let capture = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[capture])
            .replacingOccurrences(of: #"\""#, with: #"""#)
            .replacingOccurrences(of: #"\\"#, with: #"\"#)
    }
}

private extension String {
    var containsCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                true
            default:
                false
            }
        }
    }
}

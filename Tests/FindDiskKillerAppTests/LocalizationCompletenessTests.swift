import Foundation
import FindDiskKillerCore
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

@Test func coreUIStringLiteralsResolveWithoutChineseInEnglish() throws {
    let coreSources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerCore", isDirectory: true)
    let files = try swiftFiles(in: coreSources)
    var unresolved: [String] = []

    for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        for literal in swiftStringLiterals(in: source) where literal.containsCJKUnifiedIdeograph {
            if literal.contains(#"\("#) {
                if literal != #"\(name)（可能关联）"# {
                    unresolved.append("\(relativePath(file)): dynamic text must use StorageLocalizedText: \(literal)")
                }
                continue
            }
            let english = L10n.text(literal, language: .english)
            if english.containsCJKUnifiedIdeograph {
                unresolved.append("\(relativePath(file)): \(literal)")
            }
        }
    }

    #expect(
        unresolved.isEmpty,
        "Core UI text without an English resolution:\n\(unresolved.sorted().joined(separator: "\n"))"
    )
}

@Test func structuredStorageTextFormatsWithoutLeakingChineseKeys() {
    let descriptors = [
        StorageLocalizedText("独占 %@", arguments: ["5.16 GB"]),
        StorageLocalizedText("%@ 个仓库引用", arguments: ["2"]),
        StorageLocalizedText("被 %@ 个容器引用", arguments: ["3"]),
        StorageLocalizedText("%@ 宿主机物理存储", arguments: ["Docker"])
    ]

    for descriptor in descriptors {
        let localized = L10n.format(
            descriptor.key,
            arguments: descriptor.arguments,
            language: .english
        )
        #expect(!localized.containsCJKUnifiedIdeograph)
    }
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

private func relativePath(_ file: URL) -> String {
    file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
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

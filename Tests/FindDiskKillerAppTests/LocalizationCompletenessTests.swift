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
    #expect(L10n.text("Simulators", language: .simplifiedChinese) == "模拟器")
    #expect(L10n.text("Git Workspaces", language: .simplifiedChinese) == "Git 工作区")
    #expect(L10n.text("录屏保护", language: .english) == "Screen Recording")
    #expect(L10n.text("录屏时使用模拟聊天标题", language: .english) == "Use Mock Chat Titles While Recording")
    #expect(
        L10n.text("录屏保护", language: .traditionalChinese) == "錄影保護"
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

@Test func englishLocaleSensitiveFormattingNeverFallsBackToSystemChinese() {
    let duration = L10n.duration(seconds: 74_644, language: .english)
    let date = L10n.date(
        Date(timeIntervalSince1970: 1_700_000_000),
        date: .abbreviated,
        time: .standard,
        language: .english
    )
    let number = L10n.number(12_345, language: .english)
    let percent = L10n.percent(0.25, language: .english)
    let decimal = L10n.decimal(12.5, fractionDigits: 1, language: .english)

    #expect(!duration.containsCJKUnifiedIdeograph)
    #expect(!date.containsCJKUnifiedIdeograph)
    #expect(!number.containsCJKUnifiedIdeograph)
    #expect(!percent.containsCJKUnifiedIdeograph)
    #expect(!decimal.containsCJKUnifiedIdeograph)
    #expect(number == "12,345")
    #expect(percent == "25%")
    #expect(decimal == "12.5")
}

@Test func systemErrorsUseTheSelectedAppLanguageInsteadOfTheSystemLanguage() {
    let error = CocoaError(.fileReadNoPermission)
    let english = L10n.errorDescription(error, language: .english)
    let simplifiedChinese = L10n.errorDescription(error, language: .simplifiedChinese)

    #expect(english == "Operation failed (NSCocoaErrorDomain, error 257)")
    #expect(!english.containsCJKUnifiedIdeograph)
    #expect(simplifiedChinese == "操作失败（NSCocoaErrorDomain，错误代码 257）")
}

@Test func appLocaleSensitiveFormattingIsCentralizedInLocalizationLayer() throws {
    let appSources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp", isDirectory: true)
    let violations = try swiftFiles(in: appSources)
        .filter { $0.lastPathComponent != "Localization.swift" }
        .flatMap { file -> [String] in
            try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { offset, line in
                    line.contains(".formatted(") || line.contains(".localizedDescription")
                        ? "\(relativePath(file)):\(offset + 1)"
                        : nil
                }
        }

    #expect(
        violations.isEmpty,
        "Locale-sensitive formatting must use L10n so the in-app language wins:\n\(violations.joined(separator: "\n"))"
    )
}

@Test func staticUserFacingStringLiteralsUseTheLocalizationLayer() throws {
    let appSources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp", isDirectory: true)
    let sinkPattern = #"(?<![A-Za-z0-9_])(?:Text|Label|Button|Toggle|Picker|Menu|Section|GroupBox|TableColumn|ContentUnavailableView|navigationTitle|help|accessibilityLabel|accessibilityHint|alert|confirmationDialog)\s*\(\s*\"((?:\\.|[^\"\\])*)\""#
    let expression = try NSRegularExpression(pattern: sinkPattern)
    var violations: [String] = []

    for file in try swiftFiles(in: appSources) {
        let source = try String(contentsOf: file, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        for match in expression.matches(in: source, range: range) {
            guard let capture = Range(match.range(at: 1), in: source) else { continue }
            let literal = String(source[capture])
            guard !literal.contains(#"\("#), literal.requiresLocalization else { continue }
            let line = source[..<capture.lowerBound].reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            violations.append("\(relativePath(file)):\(line): \(literal)")
        }
    }

    #expect(
        violations.isEmpty,
        "Static user-facing text must resolve through L10n:\n\(violations.sorted().joined(separator: "\n"))"
    )
}

@Test func everyShippedLocalizationCatalogContainsTheSameKeys() throws {
    let resources = repositoryRoot
        .appendingPathComponent("Sources/FindDiskKillerApp/Resources", isDirectory: true)
    let catalogs = try FileManager.default.contentsOfDirectory(
        at: resources,
        includingPropertiesForKeys: [.isDirectoryKey]
    ).filter { $0.pathExtension == "lproj" }
    let simplifiedChinese = resources
        .appendingPathComponent("zh-Hans.lproj/Localizable.strings")
    let expected = try localizationKeys(in: simplifiedChinese)
    var mismatches: [String] = []

    for catalog in catalogs {
        let file = catalog.appendingPathComponent("Localizable.strings")
        let keys = try localizationKeys(in: file)
        let missing = expected.subtracting(keys)
        let unexpected = keys.subtracting(expected)
        if !missing.isEmpty || !unexpected.isEmpty {
            mismatches.append(
                "\(catalog.lastPathComponent): missing=\(missing.sorted()) unexpected=\(unexpected.sorted())"
            )
        }
    }

    #expect(
        mismatches.isEmpty,
        "Shipped localization catalogs are incomplete:\n\(mismatches.joined(separator: "\n"))"
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

private func relativePath(_ file: URL) -> String {
    file.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
}

private func localizationKeys(in file: URL) throws -> Set<String> {
    let source = try String(contentsOf: file, encoding: .utf8)
    let expression = try NSRegularExpression(pattern: #"(?m)^\"((?:\\.|[^\"\\])*)\"\s*="#)
    let range = NSRange(source.startIndex..., in: source)
    return Set(expression.matches(in: source, range: range).compactMap { match in
        guard let capture = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[capture])
    })
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
    var requiresLocalization: Bool {
        if self == "FindDiskKiller" || self == "CPU" { return false }
        if range(of: #"^[0-9.,:/%–—+ -]+(?:[KMGTPE]i?B(?:/s)?)?$"#, options: .regularExpression) != nil {
            return false
        }
        return unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

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

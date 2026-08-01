import Foundation

struct SimulatorResourceMetadata: Equatable, Sendable {
    let title: String
    let detail: String?
}

enum SimulatorStorageMetadata {
    static func device(at directory: URL, identifier: String) -> SimulatorResourceMetadata? {
        guard isDirectory(directory) else { return nil }
        let plist = propertyList(at: directory.appending(path: "device.plist")) ?? [:]
        let name = nonemptyString(plist["name"]) ?? identifier
        let runtime = nonemptyString(plist["runtime"]).map(runtimeDisplayName)
        let state = deviceState(plist["state"])
        let detail = [runtime, state]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return SimulatorResourceMetadata(
            title: name,
            detail: detail.isEmpty ? nil : detail
        )
    }

    static func runtime(at directory: URL, identifier: String) -> SimulatorResourceMetadata? {
        guard isDirectory(directory) else { return nil }
        if directory.pathExtension == "simruntime" {
            let plist = propertyList(
                at: directory.appending(path: "Contents/Info.plist")
            ) ?? [:]
            let title = nonemptyString(plist["CFBundleDisplayName"])
                ?? nonemptyString(plist["CFBundleName"])
                ?? nonemptyString(plist["CFBundleIdentifier"]).map(runtimeDisplayName)
                ?? directory.deletingPathExtension().lastPathComponent
            return SimulatorResourceMetadata(title: title, detail: nil)
        }

        if directory.pathExtension == "asset" {
            let plist = propertyList(at: directory.appending(path: "Info.plist")) ?? [:]
            let properties = plist["MobileAssetProperties"] as? [String: Any]
            guard let version = nonemptyString(properties?["SimulatorVersion"]) else {
                return SimulatorResourceMetadata(
                    title: directory.deletingPathExtension().lastPathComponent,
                    detail: nil
                )
            }
            let platform = mobileAssetPlatformName(
                bundleIdentifier: nonemptyString(plist["CFBundleIdentifier"]),
                directoryName: directory.deletingPathExtension().lastPathComponent,
                parentName: directory.deletingLastPathComponent().lastPathComponent
            )
            return SimulatorResourceMetadata(
                title: [platform, version].compactMap { $0 }.joined(separator: " "),
                detail: nil
            )
        }

        return nil
    }

    static func runtimeIdentifier(at directory: URL, fallback: String) -> String {
        guard directory.pathExtension == "simruntime",
              let plist = propertyList(at: directory.appending(path: "Contents/Info.plist")),
              let identifier = nonemptyString(plist["CFBundleIdentifier"]) else {
            return fallback
        }
        return identifier
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func runtimeDisplayName(_ identifier: String) -> String {
        let marker = ".SimRuntime."
        guard let range = identifier.range(of: marker, options: .backwards) else {
            return identifier
        }
        let suffix = String(identifier[range.upperBound...])
        guard let versionStart = suffix.firstIndex(where: { $0.isNumber }) else {
            return suffix.replacingOccurrences(of: "-", with: " ")
        }
        let platform = suffix[..<versionStart].trimmingCharacters(
            in: CharacterSet(charactersIn: "-_")
        )
        let version = suffix[versionStart...].replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) else { return nil }
        return value as? [String: Any]
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deviceState(_ value: Any?) -> String? {
        if let value = nonemptyString(value) { return value }
        guard let number = value as? NSNumber else { return nil }
        switch number.intValue {
        case 0: return "正在创建"
        case 1: return "已关机"
        case 2: return "正在启动"
        case 3: return "已启动"
        case 4: return "正在关机"
        default: return nil
        }
    }

    private static func mobileAssetPlatformName(
        bundleIdentifier: String?,
        directoryName: String,
        parentName: String
    ) -> String? {
        for value in [bundleIdentifier, parentName, directoryName].compactMap({ $0 }) {
            guard let range = value.range(of: "MobileAsset.") else { continue }
            let suffix = value[range.upperBound...]
            if let runtimeRange = suffix.range(of: "SimulatorRuntime") {
                let platform = suffix[..<runtimeRange.lowerBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
                if !platform.isEmpty { return platform }
            }
        }
        return nil
    }
}

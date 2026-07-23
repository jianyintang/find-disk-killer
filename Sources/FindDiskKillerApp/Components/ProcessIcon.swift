import AppKit
import FindDiskKillerCore
import SwiftUI

@MainActor
private final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var images: [String: NSImage] = [:]
    private var resolvedKeys: Set<String> = []

    func image(for process: ProcessActivity) async -> NSImage? {
        let cacheKey = process.id
        if resolvedKeys.contains(cacheKey) { return images[cacheKey] }

        let request = iconRequest(for: process)
        let payload = await Task.detached(priority: .utility) {
            request.load()
        }.value
        guard !Task.isCancelled else { return nil }

        resolvedKeys.insert(cacheKey)
        if let payload, let image = NSImage(data: payload.data) {
            image.isTemplate = payload.isTemplate
            images[cacheKey] = image
            return image
        }
        return nil
    }

    private func iconRequest(for process: ProcessActivity) -> ProcessIconRequest {
        let brandResourceURL = process.brand.flatMap(brandResourceURL)
        return ProcessIconRequest(
            appPath: process.appBundlePath,
            brand: process.brand,
            brandIsVerified: process.brandIsVerified,
            brandResourceURL: brandResourceURL
        )
    }

    private func brandResourceURL(_ brand: ProcessBrand) -> URL? {
        let resourceName = switch brand {
        case .codex: "codex-openai"
        case .claude: "claude-code"
        }
        return Bundle.module.url(forResource: resourceName, withExtension: "png")
    }
}

private struct ProcessIconRequest: Sendable {
    let appPath: String?
    let brand: ProcessBrand?
    let brandIsVerified: Bool
    let brandResourceURL: URL?

    func load() -> ProcessIconPayload? {
        if brandIsVerified, brand == .codex, let appPath,
           let data = try? Data(
               contentsOf: URL(fileURLWithPath: appPath)
                   .appendingPathComponent("Contents/Resources/icon-codex-dark-color.png"),
               options: .mappedIfSafe
           ) {
            return ProcessIconPayload(data: data, isTemplate: false)
        }
        if let appPath, let data = applicationIconData(at: appPath) {
            return ProcessIconPayload(data: data, isTemplate: false)
        }
        if brandIsVerified, let brandResourceURL,
           let data = try? Data(contentsOf: brandResourceURL, options: .mappedIfSafe) {
            return ProcessIconPayload(data: data, isTemplate: true)
        }
        return nil
    }

    private func applicationIconData(at appPath: String) -> Data? {
        guard let bundle = Bundle(path: appPath), let resources = bundle.resourceURL else {
            return nil
        }
        let configuredName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String
        guard let configuredName, !configuredName.isEmpty else { return nil }

        let iconURL: URL
        if URL(fileURLWithPath: configuredName).pathExtension.isEmpty {
            iconURL = resources.appendingPathComponent(configuredName).appendingPathExtension("icns")
        } else {
            iconURL = resources.appendingPathComponent(configuredName)
        }
        return try? Data(contentsOf: iconURL, options: .mappedIfSafe)
    }
}

private struct ProcessIconPayload: Sendable {
    let data: Data
    let isTemplate: Bool
}

struct ProcessIcon: View {
    let process: ProcessActivity
    var size: CGFloat = 28
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: process.brand == nil ? "terminal" : "questionmark.app")
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .foregroundStyle(.secondary)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: process.id) {
            image = await ProcessIconCache.shared.image(for: process)
        }
    }
}

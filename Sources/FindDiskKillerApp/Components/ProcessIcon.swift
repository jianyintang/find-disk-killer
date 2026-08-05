import AppKit
import FindDiskKillerCore
import ImageIO
import SwiftUI

private actor ProcessIconLoadLimiter {
    static let shared = ProcessIconLoadLimiter(maxConcurrentLoads: 2)

    private var availablePermits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentLoads: Int) {
        availablePermits = max(1, maxConcurrentLoads)
    }

    func acquire() async {
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            availablePermits += 1
            return
        }
        waiters.removeFirst().resume()
    }
}

@MainActor
private final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var images: [String: CGImage] = [:]
    private var templateKeys: Set<String> = []
    private var resolvedKeys: Set<String> = []

    func image(for process: ProcessActivity) async -> (image: CGImage, isTemplate: Bool)? {
        let cacheKey = process.id
        if resolvedKeys.contains(cacheKey) {
            return images[cacheKey].map { image in
                (image, templateKeys.contains(cacheKey))
            }
        }

        let request = iconRequest(for: process)
        let payload = await Task.detached(priority: .utility) { () -> ProcessIconPayload? in
            guard !Task.isCancelled else { return nil }
            let limiter = ProcessIconLoadLimiter.shared
            await limiter.acquire()
            let payload = Task.isCancelled ? nil : request.load()
            await limiter.release()
            return payload
        }.value
        guard !Task.isCancelled else { return nil }

        resolvedKeys.insert(cacheKey)
        if let payload {
            images[cacheKey] = payload.image
            if payload.isTemplate { templateKeys.insert(cacheKey) }
            return (payload.image, payload.isTemplate)
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
        return AppResourceBundle.value.url(forResource: resourceName, withExtension: "png")
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
            return Self.decode(data: data, isTemplate: false)
        }
        if let appPath, let data = applicationIconData(at: appPath) {
            return Self.decode(data: data, isTemplate: false)
        }
        if brandIsVerified, let brandResourceURL,
           let data = try? Data(contentsOf: brandResourceURL, options: .mappedIfSafe) {
            return Self.decode(data: data, isTemplate: true)
        }
        return nil
    }

    private static func decode(data: Data, isTemplate: Bool) -> ProcessIconPayload? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let image else { return nil }
        return ProcessIconPayload(image: image, isTemplate: isTemplate)
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

private struct ProcessIconPayload: @unchecked Sendable {
    let image: CGImage
    let isTemplate: Bool
}

struct ProcessIcon: View {
    let process: ProcessActivity
    var size: CGFloat = 28
    @State private var image: CGImage?
    @State private var isTemplate = false

    var body: some View {
        Group {
            if let image {
                if isTemplate {
                    Image(decorative: image, scale: 1)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                }
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
            guard let result = await ProcessIconCache.shared.image(for: process) else { return }
            image = result.image
            isTemplate = result.isTemplate
        }
    }
}

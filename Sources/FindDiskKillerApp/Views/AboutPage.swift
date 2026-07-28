import AppKit
import SwiftUI

struct AboutPage: View {
    private let links: BrandLinks
    private let openURL: @MainActor (URL) -> Bool
    @State private var failedURL: URL?

    init(
        links: BrandLinks = .current(),
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.links = links
        self.openURL = openURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                brandHeader
                Divider()
                VStack(spacing: 0) {
                    ExternalBrandLinkRow(
                        title: L10n.text("官网"),
                        address: links.website.host() ?? "finddiskkiller.com",
                        description: L10n.text(
                            "了解产品能力、隐私设计与常见问题，并下载签名和公证的正式版本。"
                        ),
                        url: links.website,
                        failedURL: $failedURL,
                        openURL: openURL
                    )
                    Divider()
                    ExternalBrandLinkRow(
                        title: "GitHub",
                        address: "github.com/jianyintang/find-disk-killer",
                        description: L10n.text("查看源代码和版本记录，并反馈问题。"),
                        url: links.github,
                        failedURL: $failedURL,
                        openURL: openURL
                    )
                }
                .background(Color.secondary.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("更多信息"))
                        .font(.headline)
                    HStack(spacing: 18) {
                        compactLink(
                            L10n.text("隐私政策"),
                            symbol: "hand.raised",
                            url: links.privacyPolicy
                        )
                        compactLink(
                            L10n.text("获取支持"),
                            symbol: "questionmark.circle",
                            url: links.support
                        )
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var brandHeader: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 76, height: 76)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("FindDiskKiller")
                    .font(.title.bold())
                Text(versionDescription)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(L10n.text("在本机发现持续写盘、异常负载和磁盘健康信号。"))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func compactLink(_ title: String, symbol: String, url: URL) -> some View {
        Button {
            if !openURL(url) { failedURL = url }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.link)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint(L10n.text("在默认浏览器中打开"))
        .contextMenu { copyButton(url) }
    }

    private func copyButton(_ url: URL) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        } label: {
            Label(L10n.text("复制链接"), systemImage: "doc.on.doc")
        }
    }

    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "-"
        return L10n.format("版本 %@（%@）", version, build)
    }
}

private struct ExternalBrandLinkRow: View {
    let title: String
    let address: String
    let description: String
    let url: URL
    @Binding var failedURL: URL?
    let openURL: @MainActor (URL) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.headline)
                        Text(address)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 20)
                    Image(systemName: "arrow.up.right")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .padding(18)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityHint(L10n.text("在默认浏览器中打开"))
            .contextMenu {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: {
                    Label(L10n.text("复制链接"), systemImage: "doc.on.doc")
                }
            }

            if failedURL == url {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(L10n.text("无法打开默认浏览器，你可以复制链接后重试。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("复制链接")) { copyURL() }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }

    private func open() {
        failedURL = openURL(url) ? nil : url
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

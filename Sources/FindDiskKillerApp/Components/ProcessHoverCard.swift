import AppKit
import FindDiskKillerCore
import SwiftUI

struct ProcessHoverCard: View {
    let process: ProcessActivity
    @Environment(\.colorScheme) private var colorScheme

    private var profile: ProcessKnowledgeProfile {
        ProcessKnowledge.profile(for: process)
    }

    private var assessment: ProcessLoadAssessment {
        ProcessLoadAssessment.assess(process)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProcessIcon(process: process, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(process.localizedDisplayName)
                            .font(.headline)
                            .lineLimit(1)
                        Label(profile.role, systemImage: profile.symbol)
                            .font(.caption)
                            .foregroundStyle(profile.color)
                    }
                }

                Text(profile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Divider()

                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: assessment.symbol)
                        .foregroundStyle(assessment.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(assessment.title)
                            .font(.subheadline.weight(.semibold))
                        Text(assessment.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        metric("CPU · 5 秒", PercentFormatter.cpu(process.currentCPUPercent), .blue)
                        metric("读取", ByteRateFormatter.rate(process.currentReadBytesPerSecond), .teal)
                        metric("写入", ByteRateFormatter.rate(process.currentWriteBytesPerSecond), .orange)
                    }
                    GridRow {
                        metric("下载", networkValue(process.currentNetworkReceiveBytesPerSecond), .green)
                        metric("上传", networkValue(process.currentNetworkSendBytesPerSecond), .indigo)
                        metric("进程", process.memberCount.formatted(), .secondary)
                    }
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
        .frame(width: 340)
        .frame(minHeight: 1, idealHeight: 236, maxHeight: 236)
        .background(cardSurface)
        .background(PopoverMousePassthroughConfigurator())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func networkValue(_ value: Double) -> String {
        process.isNetworkAvailable ? ByteRateFormatter.rate(value) : L10n.text("不可用")
    }

    private var cardSurface: Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.105, blue: 0.11)
            : Color(red: 0.985, green: 0.985, blue: 0.99)
    }
}

private struct PopoverMousePassthroughConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> PassthroughView {
        PassthroughView()
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        nsView.configureWindow()
    }

    final class PassthroughView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            window?.ignoresMouseEvents = true
        }
    }
}

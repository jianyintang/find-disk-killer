import FindDiskKillerCore
import SwiftUI

struct SectionHeading<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.headline)
                if let subtitle {
                    Text(L10n.text(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

extension SectionHeading where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

struct MetricValue: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text(value))
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct EvidenceLabel: View {
    let text: String
    let symbol: String
    var color: Color = .secondary

    var body: some View {
        Label(L10n.text(text), systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

struct NetworkMetricValue: View {
    let download: Double
    let upload: Double
    let isAvailable: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("网络 · 最近 5 秒"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isAvailable {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            networkRate(download, symbol: "arrow.down", color: .green)
                            networkRate(upload, symbol: "arrow.up", color: .indigo)
                        }
                        .fixedSize(horizontal: true, vertical: false)

                        VStack(alignment: .leading, spacing: 1) {
                            networkRate(download, symbol: "arrow.down", color: .green)
                            networkRate(upload, symbol: "arrow.up", color: .indigo)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Text(L10n.text("采样缺口"))
                        .font(.callout.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func networkRate(_ value: Double, symbol: String, color: Color) -> some View {
        Label(ByteRateFormatter.rate(value), systemImage: symbol)
            .font(.system(.callout, design: .monospaced, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

import FindDiskKillerCore
import SwiftUI

enum AppActionButtonKind {
    case primary
    case secondary
    case destructive
}

enum AppActionButtonSize {
    case compact
    case regular
    case large

    var minimumHeight: CGFloat {
        switch self {
        case .compact: 30
        case .regular: 34
        case .large: 38
        }
    }

    fileprivate var horizontalPadding: CGFloat {
        switch self {
        case .compact: 10
        case .regular: 13
        case .large: 16
        }
    }

    fileprivate var font: Font {
        switch self {
        case .compact: .caption.weight(.semibold)
        case .regular: .callout.weight(.semibold)
        case .large: .body.weight(.semibold)
        }
    }

    fileprivate var cornerRadius: CGFloat {
        self == .compact ? 6 : 7
    }
}

struct AppActionButtonStyle: ButtonStyle {
    let kind: AppActionButtonKind
    var size: AppActionButtonSize = .regular

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        AppActionButtonBody(
            label: configuration.label,
            kind: kind,
            size: size,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct AppActionButtonBody<Label: View>: View {
    let label: Label
    let kind: AppActionButtonKind
    let size: AppActionButtonSize
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false

    var body: some View {
        label
            .font(size.font)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minimumHeight)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: size.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius)
                    .stroke(borderColor, lineWidth: kind == .secondary ? 0.75 : 0.5)
            }
            .shadow(
                color: shadowColor,
                radius: kind == .secondary ? 0 : 2,
                y: kind == .secondary ? 0 : 1
            )
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius))
            .opacity(isEnabled ? 1 : 0.46)
            .scaleEffect(isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var foregroundColor: Color {
        switch kind {
        case .primary, .destructive: .white
        case .secondary: .primary
        }
    }

    private var backgroundColor: Color {
        switch kind {
        case .primary:
            return Color.accentColor.opacity(isPressed ? 0.78 : isHovering ? 0.9 : 1)
        case .secondary:
            if isPressed { return Color.primary.opacity(0.13) }
            if isHovering { return Color.primary.opacity(0.09) }
            return Color(nsColor: .controlBackgroundColor).opacity(0.92)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.78 : isHovering ? 0.9 : 1)
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .white.opacity(0.18)
        case .secondary: Color(nsColor: .separatorColor).opacity(0.9)
        case .destructive: .white.opacity(0.2)
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary: Color.accentColor.opacity(0.2)
        case .secondary: .clear
        case .destructive: Color.red.opacity(0.2)
        }
    }
}

struct AppIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var isFramed = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        AppIconButtonBody(
            label: configuration.label,
            size: size,
            isFramed: isFramed,
            isEnabled: isEnabled,
            isPressed: configuration.isPressed
        )
    }
}

private struct AppIconButtonBody<Label: View>: View {
    let label: Label
    let size: CGFloat
    let isFramed: Bool
    let isEnabled: Bool
    let isPressed: Bool

    @State private var isHovering = false

    var body: some View {
        label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isFramed {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.72), lineWidth: 0.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard isFramed else { return isHovering ? Color.primary.opacity(0.07) : .clear }
        if isPressed { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.1) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }
}

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

import FindDiskKillerCore
import SwiftUI

struct StorageMapFirstRunView: View {
    let candidates: [StorageSourceCandidate]
    let errorMessage: String?
    let startAnalysis: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                if proxy.size.width >= 820 {
                    desktopTopology
                        .frame(width: proxy.size.width, alignment: .topLeading)
                        .frame(minHeight: max(500, proxy.size.height - 78))
                } else {
                    compactTopology
                        .frame(width: proxy.size.width, alignment: .topLeading)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionDock
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var desktopTopology: some View {
        HStack(alignment: .top, spacing: 0) {
            scanCenter
                .frame(width: 360)
                .padding(.top, 34)

            topologyRail
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 30)
                .padding(.trailing, 32)
                .padding(.bottom, 28)
        }
    }

    private var compactTopology: some View {
        VStack(alignment: .leading, spacing: 30) {
            scanCenter
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.text("本次扫描路径"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)

                ForEach(Array(familyPlans.enumerated()), id: \.element.id) { index, plan in
                    CompactTopologyBranch(
                        plan: plan,
                        isLast: index == familyPlans.count - 1
                    )
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
    }

    private var scanCenter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(L10n.text("扫描范围已确认"), systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)

            Text(L10n.text("建立这台 Mac 的空间地图"))
                .font(.system(size: 28, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)

            Text(L10n.text("从已知位置开始，厘清应用、工具与运行环境的本机占用。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            HStack(alignment: .firstTextBaseline, spacing: 20) {
                scanMetric(value: candidates.count, title: L10n.text("来源"))
                scanMetric(value: rootCount, title: L10n.text("已知位置"))
            }
            .padding(.top, 26)

            if let errorMessage {
                Label(L10n.text("上次分析未完成"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(errorMessage)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scanMetric(value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var topologyRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("本次扫描路径"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.text("连线表示扫描归属，不表示容量大小"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(L10n.text("仅已知位置"), systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 34)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(familyPlans.enumerated()), id: \.element.id) { index, plan in
                    DesktopTopologyBranch(
                        plan: plan,
                        isFirst: index == 0,
                        isLast: index == familyPlans.count - 1
                    )
                }
            }
        }
    }

    private var actionDock: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                HStack(spacing: 16) {
                    boundary(L10n.text("本机完成"), symbol: "macbook")
                    boundary(L10n.text("只读元数据"), symbol: "doc.text.magnifyingglass")
                    boundary(L10n.text("不执行清理"), symbol: "hand.raised.fill")
                }

                Spacer(minLength: 12)
                analysisButton
            }

            HStack(spacing: 12) {
                Label(L10n.text("本机只读分析，不执行清理"), systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                analysisButton
            }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 66)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var analysisButton: some View {
        Button(action: startAnalysis) {
            Label(
                L10n.format("开始分析 · %d 个位置", rootCount),
                systemImage: "play.fill"
            )
            .frame(minWidth: 176)
        }
        .buttonStyle(AppActionButtonStyle(kind: .primary, size: .large))
        .keyboardShortcut(.defaultAction)
    }

    private func boundary(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var rootCount: Int {
        candidates.reduce(0) { $0 + $1.roots.count }
    }

    private var familyPlans: [StorageTopologyFamily] {
        StorageSourceFamily.allCases.compactMap { family in
            let matches = candidates.filter { $0.descriptor.family == family }
            guard !matches.isEmpty else { return nil }
            return StorageTopologyFamily(family: family, candidates: matches)
        }
    }
}

private struct DesktopTopologyBranch: View {
    let plan: StorageTopologyFamily
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: plan.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(plan.color)
                    .frame(width: 22, height: 22)
                Text(plan.title)
                    .font(.subheadline.weight(.semibold))
                Text(L10n.format("%d 个来源 · %d 个位置", plan.candidates.count, plan.rootCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112, maximum: 168), spacing: 18)],
                alignment: .leading,
                spacing: 11
            ) {
                ForEach(plan.candidates) { candidate in
                    TopologySourceNode(
                        candidate: candidate,
                        color: plan.color
                    )
                }
            }
        }
        .padding(.leading, 34)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            topologyConnector
                .frame(width: 34)
        }
    }

    private var topologyConnector: some View {
        GeometryReader { _ in
            Canvas { context, size in
                let x: CGFloat = 9
                let branchY: CGFloat = 11
                var vertical = Path()
                vertical.move(to: CGPoint(x: x, y: isFirst ? branchY : 0))
                vertical.addLine(to: CGPoint(x: x, y: isLast ? branchY : size.height))
                context.stroke(vertical, with: .color(Color.secondary.opacity(0.24)), lineWidth: 1)

                var branch = Path()
                branch.move(to: CGPoint(x: x, y: branchY))
                branch.addLine(to: CGPoint(x: size.width - 5, y: branchY))
                context.stroke(branch, with: .color(plan.color.opacity(0.72)), lineWidth: 1.5)

                context.fill(
                    Path(ellipseIn: CGRect(x: x - 3, y: branchY - 3, width: 6, height: 6)),
                    with: .color(plan.color)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CompactTopologyBranch: View {
    let plan: StorageTopologyFamily
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(plan.color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 8)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: plan.symbol).foregroundStyle(plan.color)
                    Text(plan.title).font(.subheadline.weight(.semibold))
                    Text(L10n.format("%d 个位置", plan.rootCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 138, maximum: 190),
                            spacing: 18,
                            alignment: .leading
                        )
                    ],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(plan.candidates) { candidate in
                        TopologySourceNode(
                            candidate: candidate,
                            color: plan.color
                        )
                    }
                }
                .padding(.bottom, isLast ? 0 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TopologySourceNode: View {
    let candidate: StorageSourceCandidate
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: candidate.descriptor.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.descriptor.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(sourceActionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "scope")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(sourceActionTitle)
    }

    private var sourceActionTitle: String {
        if candidate.id == .codex || candidate.id == .claude {
            return L10n.text("聊天与子代理")
        }
        return L10n.format("%d 个位置", candidate.roots.count)
    }
}

private struct StorageTopologyFamily: Identifiable {
    let family: StorageSourceFamily
    let candidates: [StorageSourceCandidate]

    var id: String { family.rawValue }
    var rootCount: Int { candidates.reduce(0) { $0 + $1.roots.count } }

    var title: String {
        switch family {
        case .applications: L10n.text("应用与浏览器")
        case .developerTools: L10n.text("开发工具")
        case .containers: L10n.text("容器")
        case .aiTools: L10n.text("AI 工具")
        case .workspaces: L10n.text("工作区")
        }
    }

    var symbol: String {
        switch family {
        case .applications: "safari"
        case .developerTools: "hammer"
        case .containers: "shippingbox"
        case .aiTools: "sparkles"
        case .workspaces: "folder.badge.gearshape"
        }
    }

    var color: Color {
        switch family {
        case .applications: .cyan
        case .developerTools: .green
        case .containers: .orange
        case .aiTools: .pink
        case .workspaces: .secondary
        }
    }
}

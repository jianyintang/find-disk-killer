import FindDiskKillerCore
import SwiftUI

struct MenuBarPanel: View {
    let store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            metricsRow(
                left: MetricValue(
                    title: "读取",
                    value: store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentReadRate)
                        : "采样缺口",
                    symbol: "eye",
                    color: InstrumentDesign.ColorRole.diskRead
                ),
                right: MetricValue(
                    title: "写入",
                    value: store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentWriteRate)
                        : "采样缺口",
                    symbol: "pencil.line",
                    color: InstrumentDesign.ColorRole.diskWrite
                )
            )
            Divider()
            metricsRow(
                left: MetricValue(
                    title: "CPU",
                    value: store.isSystemCPUAvailable
                        ? PercentFormatter.cpu(store.currentCPUPercent)
                        : "采样缺口",
                    symbol: "cpu",
                    color: .blue
                ),
                right: MetricValue(
                    title: "网络",
                    value: store.isSystemNetworkAvailable
                        ? "↓ \(ByteRateFormatter.rate(store.currentNetworkReceiveRate))  ↑ \(ByteRateFormatter.rate(store.currentNetworkSendRate))"
                        : "不可用",
                    symbol: "network",
                    color: .green
                )
            )
            Divider()
            topWriterRow
            quitRow
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        Button(action: openMainWindow) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(L10n.text("应用资源行为 · 持续监控"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.title3)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("打开 FindDiskKiller"))
        .accessibilityLabel(L10n.text("打开 FindDiskKiller"))
    }

    private func metricsRow(left: MetricValue, right: MetricValue) -> some View {
        Button(action: openMainWindow) {
            HStack(spacing: 14) {
                left
                right
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("打开 FindDiskKiller"))
        .accessibilityLabel(L10n.text("打开 FindDiskKiller"))
    }

    private var topWriterRow: some View {
        HStack(spacing: 10) {
            Button(action: openMainWindow) {
                topWriterSummary
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("打开 FindDiskKiller"))
            .accessibilityLabel(L10n.text("打开 FindDiskKiller"))
            collectionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    @ViewBuilder
    private var topWriterSummary: some View {
        HStack(spacing: 10) {
            if let top = store.topWriter {
                ProcessIcon(process: top, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.localizedDisplayName)
                        .lineLimit(1)
                    Text(L10n.format(
                        "当前写入最高 · %@",
                        ByteRateFormatter.rate(top.currentWriteBytesPerSecond)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("暂无最高写入"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L10n.text(store.isCollecting ? "采集进行中" : "等待写入活动"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Match the main-window toolbar collection control (play/stop, neutral icon chrome).
    private var collectionButton: some View {
        let title = L10n.text(store.isCollecting ? "停止采集" : "开始采集")
        return Button {
            store.isCollecting ? store.stop() : store.start()
        } label: {
            Image(systemName: store.isCollecting ? "stop.fill" : "play.fill")
        }
        .buttonStyle(AppIconButtonStyle(size: 30))
        .help(title)
        .accessibilityLabel(title)
    }

    /// Dedicated bottom action — restrained chrome so it stays secondary to metrics.
    private var quitRow: some View {
        let title = L10n.text("退出应用")
        return Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .background {
            ZStack(alignment: .top) {
                Color(nsColor: .controlBackgroundColor).opacity(0.18)
                Divider()
            }
        }
    }

    private func openMainWindow() {
        AppActivationPolicy.applyPreferred()
        openWindow(id: "main")
        DispatchQueue.main.async {
            let window = NSApp.windows.first {
                $0.identifier?.rawValue == "main" || $0.title == "FindDiskKiller"
            }
            window?.deminiaturize(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var statusTitle: String {
        switch store.health {
        case .starting: L10n.text("正在建立采样")
        case .normal: L10n.text("磁盘活动正常")
        case .elevated: L10n.text("检测到持续写入")
        case .stopped: L10n.text("采集已停止")
        case .unavailable: L10n.text("采集不可用")
        }
    }

    private var statusSymbol: String {
        switch store.health {
        case .elevated: "exclamationmark.triangle.fill"
        case .stopped: "pause.circle.fill"
        case .unavailable: "xmark.octagon.fill"
        default: "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch store.health {
        case .elevated: .orange
        case .stopped: .secondary
        case .unavailable: .red
        default: .green
        }
    }
}

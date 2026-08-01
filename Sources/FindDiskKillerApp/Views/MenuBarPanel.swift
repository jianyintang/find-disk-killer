import FindDiskKillerCore
import SwiftUI

struct MenuBarPanel: View {
    let store: MonitorStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            Divider()

            HStack(spacing: 14) {
                MetricValue(
                    title: "读取",
                    value: store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentReadRate)
                        : "采样缺口",
                    symbol: "eye",
                    color: .teal
                )
                MetricValue(
                    title: "写入",
                    value: store.isDiskAvailable
                        ? ByteRateFormatter.rate(store.currentWriteRate)
                        : "采样缺口",
                    symbol: "pencil.line",
                    color: .orange
                )
            }
            .padding(14)

            Divider()

            HStack(spacing: 14) {
                MetricValue(
                    title: "CPU",
                    value: store.isSystemCPUAvailable
                        ? PercentFormatter.cpu(store.currentCPUPercent)
                        : "采样缺口",
                    symbol: "cpu",
                    color: .blue
                )
                MetricValue(
                    title: "网络",
                    value: store.isSystemNetworkAvailable
                        ? "↓ \(ByteRateFormatter.rate(store.currentNetworkReceiveRate))  ↑ \(ByteRateFormatter.rate(store.currentNetworkSendRate))"
                        : "不可用",
                    symbol: "network",
                    color: .green
                )
            }
            .padding(14)

            if let top = store.topWriter {
                Divider()
                HStack(spacing: 10) {
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
                    Spacer()
                }
                .padding(14)
            }

            Divider()

            HStack {
                Button {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(L10n.text("打开 FindDiskKiller"), systemImage: "macwindow")
                }
                .buttonStyle(AppActionButtonStyle(kind: .primary, size: .compact))

                Spacer()

                Button {
                    store.isCollecting ? store.stop() : store.start()
                } label: {
                    Image(systemName: store.isCollecting ? "stop.fill" : "play.fill")
                }
                .buttonStyle(AppIconButtonStyle(size: 30))
                .help(L10n.text(store.isCollecting ? "停止采集" : "开始采集"))
            }
            .padding(12)
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

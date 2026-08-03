import AppKit
import CoreGraphics
import CoreText
import FindDiskKillerCore
import Foundation

enum HistoryExportFormat: Sendable {
    case pdf
    case csv

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .csv: "csv"
        }
    }
}

enum HistoryReportExporter {
    @MainActor
    static func presentSavePanel(
        for report: HistoryReport,
        format: HistoryExportFormat
    ) async throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .pdf ? [.pdf] : [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename(for: report, format: format)
        panel.message = L10n.text("导出包含聚合资源统计和应用名称；请选择可信的位置。")
        guard await panel.begin() == .OK, let url = panel.url else { return }

        let data = try await Task.detached(priority: .userInitiated) {
            switch format {
            case .pdf: try pdfData(for: report)
            case .csv: csvData(for: report)
            }
        }.value
        try data.write(to: url, options: .atomic)
    }

    private static func defaultFilename(
        for report: HistoryReport,
        format: HistoryExportFormat
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "FindDiskKiller-history-\(formatter.string(from: report.end)).\(format.fileExtension)"
    }

    static func csvData(for report: HistoryReport) -> Data {
        var rows = [
            "timestamp_iso8601,duration_seconds,disk_read_bytes,disk_write_bytes,"
                + "network_receive_bytes,network_send_bytes,average_cpu_percent,"
                + "peak_cpu_percent,disk_observed_seconds,network_observed_seconds,"
                + "cpu_observed_seconds,disk_coverage_ratio,network_coverage_ratio,"
                + "cpu_coverage_ratio,report_coverage_ratio,partial"
        ]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for point in report.trend {
            rows.append([
                csv(formatter.string(from: point.timestamp)),
                number(point.duration),
                point.diskObservedSeconds > 0 ? String(point.diskReadBytes) : "",
                point.diskObservedSeconds > 0 ? String(point.diskWriteBytes) : "",
                point.networkObservedSeconds > 0 ? String(point.networkReceiveBytes) : "",
                point.networkObservedSeconds > 0 ? String(point.networkSendBytes) : "",
                optionalNumber(point.averageCPUPercent),
                optionalNumber(point.peakCPUPercent),
                number(point.diskObservedSeconds),
                number(point.networkObservedSeconds),
                number(point.cpuObservedSeconds),
                number(report.summary.diskCoverage),
                number(report.summary.networkCoverage),
                number(report.summary.cpuCoverage),
                number(report.summary.coverage),
                min(
                    report.summary.diskCoverage,
                    report.summary.networkCoverage,
                    report.summary.cpuCoverage
                ) < 0.7 ? "true" : "false"
            ].joined(separator: ","))
        }
        return Data((rows.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func pdfData(for report: HistoryReport) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)

        let content = pdfText(for: report)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        let attributed = NSAttributedString(
            string: content,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 48, y: 48, width: 499, height: 746), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func pdfText(
        for report: HistoryReport,
        language: AppLanguage = L10n.effectiveLanguage
    ) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let coverage = L10n.percent(report.summary.coverage, fractionDigits: 1, language: language)
        let diskCoverage = L10n.percent(report.summary.diskCoverage, fractionDigits: 1, language: language)
        let networkCoverage = L10n.percent(report.summary.networkCoverage, fractionDigits: 1, language: language)
        let cpuCoverage = L10n.percent(report.summary.cpuCoverage, fractionDigits: 1, language: language)
        let applications = report.applications.prefix(12).enumerated().map { index, app in
            "\(index + 1). \(app.name)  "
                + "\(L10n.text("写入", language: language)) \(applicationMetric(app.writeBytes, .write, app, language: language))  "
                + "\(L10n.text("读取", language: language)) \(applicationMetric(app.readBytes, .read, app, language: language))"
        }.joined(separator: "\n")
        return """
        FindDiskKiller - \(L10n.text("历史分析", language: language))

        \(L10n.text("分析周期", language: language)): \(dateFormatter.string(from: report.start)) - \(dateFormatter.string(from: report.end))
        \(L10n.text("数据覆盖", language: language)): \(coverage)
        \(L10n.text("磁盘 I/O", language: language)) · \(L10n.text("数据覆盖", language: language)): \(diskCoverage)
        CPU · \(L10n.text("数据覆盖", language: language)): \(cpuCoverage)
        \(L10n.text("网络", language: language)) · \(L10n.text("数据覆盖", language: language)): \(networkCoverage)

        \(L10n.text("物理写入", language: language)): \(report.summary.diskObservedSeconds > 0
            ? ByteRateFormatter.bytes(report.summary.diskWriteBytes)
            : L10n.text("不可用", language: language))
        \(L10n.text("物理读取", language: language)): \(report.summary.diskObservedSeconds > 0
            ? ByteRateFormatter.bytes(report.summary.diskReadBytes)
            : L10n.text("不可用", language: language))
        \(L10n.text("平均 CPU", language: language)): \(report.summary.averageCPUPercent.map(PercentFormatter.cpu) ?? L10n.text("不可用", language: language))
        \(L10n.text("网络传输", language: language)): \(report.summary.networkObservedSeconds > 0
            ? ByteRateFormatter.bytes(
                report.summary.networkReceiveBytes + report.summary.networkSendBytes
            )
            : L10n.text("不可用", language: language))

        \(L10n.text("主要应用", language: language))
        \(applications.isEmpty ? L10n.text("这个周期还没有应用级活动。", language: language) : applications)

        \(L10n.text("数据质量", language: language))
        \(L10n.text("上一周期数据不足；当前结论仅基于已覆盖时间，不会用零值补齐缺口。", language: language))

        \(L10n.text("导出包含聚合资源统计和应用名称；请选择可信的位置。", language: language))
        """
    }

    private static func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func optionalNumber(_ value: Double?) -> String {
        value.map(number) ?? ""
    }

    private static func applicationMetric(
        _ value: UInt64,
        _ metric: HistoryApplicationMetricSet,
        _ application: HistoryApplicationReport,
        language: AppLanguage
    ) -> String {
        application.unavailableMetrics.contains(metric)
            ? L10n.text("不可用", language: language)
            : ByteRateFormatter.bytes(value)
    }
}

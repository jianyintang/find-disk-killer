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

    static func pdfText(for report: HistoryReport) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let coverage = String(format: "%.1f%%", report.summary.coverage * 100)
        let diskCoverage = String(format: "%.1f%%", report.summary.diskCoverage * 100)
        let networkCoverage = String(format: "%.1f%%", report.summary.networkCoverage * 100)
        let cpuCoverage = String(format: "%.1f%%", report.summary.cpuCoverage * 100)
        let applications = report.applications.prefix(12).enumerated().map { index, app in
            "\(index + 1). \(app.name)  "
                + "write \(applicationMetric(app.writeBytes, .write, app))  "
                + "read \(applicationMetric(app.readBytes, .read, app))"
        }.joined(separator: "\n")
        return """
        FindDiskKiller - History Analysis

        Range: \(dateFormatter.string(from: report.start)) to \(dateFormatter.string(from: report.end))
        Generated: \(dateFormatter.string(from: Date()))
        Coverage: \(coverage)
        Disk coverage: \(diskCoverage)
        CPU coverage: \(cpuCoverage)
        Network coverage: \(networkCoverage)

        Physical disk writes: \(report.summary.diskObservedSeconds > 0
            ? ByteRateFormatter.bytes(report.summary.diskWriteBytes)
            : "Unavailable")
        Physical disk reads: \(report.summary.diskObservedSeconds > 0
            ? ByteRateFormatter.bytes(report.summary.diskReadBytes)
            : "Unavailable")
        Average CPU: \(report.summary.averageCPUPercent.map(PercentFormatter.cpu) ?? "Unavailable")
        Network transfer: \(report.summary.networkObservedSeconds > 0
            ? ByteRateFormatter.bytes(
                report.summary.networkReceiveBytes + report.summary.networkSendBytes
            )
            : "Unavailable")

        Leading applications (logical activity)
        \(applications.isEmpty ? "No application detail for this period." : applications)

        Data quality
        Findings and comparisons are based only on covered intervals. Missing time is not filled with zeroes.

        Generated locally on this Mac. This file contains aggregate resource statistics and application names.
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
        _ application: HistoryApplicationReport
    ) -> String {
        application.unavailableMetrics.contains(metric)
            ? "Unavailable"
            : ByteRateFormatter.bytes(value)
    }
}

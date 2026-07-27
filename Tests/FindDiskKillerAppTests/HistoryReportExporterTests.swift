import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

@Test func historyCSVUsesStableMachineColumnsAndQualityMetadata() throws {
    let report = HistoryReport.exportFixture
    let data = HistoryReportExporter.csvData(for: report)
    let text = try #require(String(data: data, encoding: .utf8))

    #expect(text.hasPrefix("timestamp_iso8601,duration_seconds,disk_read_bytes"))
    #expect(text.contains("disk_coverage_ratio,network_coverage_ratio,cpu_coverage_ratio"))
    #expect(text.contains("report_coverage_ratio,partial\r\n"))
    #expect(text.contains("0.500000,true"))
    #expect(!text.contains("/Applications"))
    #expect(!text.lowercased().contains("pid"))
}

@Test func historyPDFIsGeneratedLocallyFromTheSnapshot() throws {
    let data = try HistoryReportExporter.pdfData(for: .exportFixture)
    #expect(data.starts(with: Data("%PDF".utf8)))
    #expect(data.count > 1_000)
}

private extension HistoryReport {
    static var exportFixture: Self {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return HistoryReport(
            range: .sevenDays,
            start: start,
            end: start.addingTimeInterval(900),
            summary: HistorySummary(
                diskReadBytes: 20,
                diskWriteBytes: 10,
                networkReceiveBytes: 30,
                networkSendBytes: 40,
                averageCPUPercent: 12,
                peakCPUPercent: 25,
                observedSeconds: 450,
                coverage: 0.5
            ),
            trend: [HistoryTrendPoint(
                timestamp: start,
                duration: 450,
                diskReadBytes: 20,
                diskWriteBytes: 10,
                networkReceiveBytes: 30,
                networkSendBytes: 40,
                averageCPUPercent: 12,
                peakCPUPercent: 25
            )],
            applications: [HistoryApplicationReport(
                id: "safe-id",
                name: "Example, App",
                readBytes: 20,
                writeBytes: 10,
                networkReceiveBytes: 30,
                networkSendBytes: 40,
                cpuTimeNanoseconds: 1_000_000_000
            )],
            previousPeriodDiskWriteBytes: nil
        )
    }
}

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

@Test func historyPDFMarksUnavailableApplicationMetricsWithoutRenderingTheSentinel() throws {
    let report = HistoryReport.exportFixtureWithUnavailableWrite
    let data = try HistoryReportExporter.pdfData(for: report)
    let text = HistoryReportExporter.pdfText(for: report, language: .english)

    #expect(!text.contains(String(Int64.max)))
    #expect(text.contains("Write Unavailable"))
    #expect(text.contains("Read 20 B"))
    #expect(data.count > 1_000)
}

@Test func historyPDFTextFollowsTheSelectedApplicationLanguage() {
    let report = HistoryReport.exportFixtureWithUnavailableWrite
    let english = HistoryReportExporter.pdfText(for: report, language: .english)
    let simplifiedChinese = HistoryReportExporter.pdfText(
        for: report,
        language: .simplifiedChinese
    )

    #expect(english.contains("History"))
    #expect(english.contains("Write Unavailable"))
    #expect(!english.containsCJKUnifiedIdeograph)
    #expect(simplifiedChinese.contains("历史分析"))
    #expect(simplifiedChinese.contains("写入 不可用"))
}

private extension String {
    var containsCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
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

    static var exportFixtureWithUnavailableWrite: Self {
        let fixture = exportFixture
        return Self(
            range: fixture.range,
            start: fixture.start,
            end: fixture.end,
            summary: fixture.summary,
            trend: fixture.trend,
            applications: [HistoryApplicationReport(
                id: "unavailable-write",
                name: "Saturated Writer",
                readBytes: 20,
                writeBytes: 0,
                networkReceiveBytes: 30,
                networkSendBytes: 40,
                cpuTimeNanoseconds: 1_000_000_000,
                unavailableMetrics: [.write]
            )],
            previousPeriodDiskWriteBytes: fixture.previousPeriodDiskWriteBytes
        )
    }
}

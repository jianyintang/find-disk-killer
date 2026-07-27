import Foundation
import Testing
@testable import FindDiskKillerApp
@testable import FindDiskKillerCore

@Test func historyViewportAddsTrailingBlankWithoutMovingTheData() {
    let start = Date(timeIntervalSince1970: 1_000)
    let end = start.addingTimeInterval(1_000)

    let viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 400,
        trailingBlankFraction: 0.15
    )

    #expect(viewport.domain.lowerBound == start)
    #expect(viewport.domain.upperBound == end.addingTimeInterval(60))
    #expect(viewport.scrollPosition == end.addingTimeInterval(-340))
}

@Test func historyViewportClampsScrollingAtBothEnds() {
    let start = Date(timeIntervalSince1970: 2_000)
    let end = start.addingTimeInterval(1_000)
    var viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 250,
        trailingBlankFraction: 0.1
    )

    viewport.scroll(to: start.addingTimeInterval(-500))
    #expect(viewport.scrollPosition == viewport.minimumScrollPosition)

    viewport.scroll(to: end.addingTimeInterval(500))
    #expect(viewport.scrollPosition == viewport.maximumScrollPosition)
}

@Test func historyViewportZoomKeepsTheRequestedAnchorStable() {
    let start = Date(timeIntervalSince1970: 3_000)
    let end = start.addingTimeInterval(2_000)
    var viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 800,
        trailingBlankFraction: 0.1
    )
    viewport.scroll(to: start.addingTimeInterval(400))
    let anchor = start.addingTimeInterval(720)
    let ratioBefore = anchor.timeIntervalSince(viewport.scrollPosition) / viewport.visibleDuration

    viewport.zoom(by: 0.5, anchor: anchor)

    let ratioAfter = anchor.timeIntervalSince(viewport.scrollPosition) / viewport.visibleDuration
    #expect(abs(ratioAfter - ratioBefore) < 0.000_001)
    #expect(viewport.visibleDuration == 400)
}

@Test func historyViewportSelectionDoesNotChangeTheVisibleWindow() {
    let start = Date(timeIntervalSince1970: 4_000)
    let end = start.addingTimeInterval(1_000)
    let viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 300,
        trailingBlankFraction: 0.1
    )
    let originalPosition = viewport.scrollPosition
    let originalDuration = viewport.visibleDuration

    _ = viewport.nearestDate(to: end, candidates: [start, start.addingTimeInterval(500), end])

    #expect(viewport.scrollPosition == originalPosition)
    #expect(viewport.visibleDuration == originalDuration)
}

@Test func historyViewportProgressMapsAcrossScrollableRange() {
    let start = Date(timeIntervalSince1970: 5_000)
    let end = start.addingTimeInterval(1_000)
    var viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 200,
        trailingBlankFraction: 0.1
    )

    viewport.setProgress(0)
    #expect(viewport.scrollProgress == 0)
    viewport.setProgress(0.5)
    #expect(abs(viewport.scrollProgress - 0.5) < 0.000_001)
    viewport.setProgress(1)
    #expect(abs(viewport.scrollProgress - 1) < 0.000_001)
}

@Test func historyViewportNeverScrollsPastItsProportionalTrailingBlank() {
    let start = Date(timeIntervalSince1970: 6_000)
    let end = start.addingTimeInterval(365 * 86_400)
    var viewport = HistoryChartViewport(
        dataDomain: start...end,
        visibleDuration: 30 * 86_400,
        trailingBlankFraction: 0.15,
        minimumVisibleDuration: 3_600
    )

    viewport.zoom(by: 0.001, anchor: end)
    viewport.setProgress(1)

    let visibleEnd = viewport.scrollPosition.addingTimeInterval(viewport.visibleDuration)
    let trailingBlank = visibleEnd.timeIntervalSince(end)
    #expect(trailingBlank >= 0)
    #expect(trailingBlank <= viewport.visibleDuration * 0.15 + 0.001)
    #expect(end >= viewport.scrollPosition)
    #expect(end <= visibleEnd)
}

@MainActor
@Test func historyChartMinimumZoomFollowsCompactedSamplingInterval() {
    let start = Date(timeIntervalSince1970: 7_000)
    let points = (0..<20).map { index in
        HistoryTrendPoint(
            timestamp: start.addingTimeInterval(TimeInterval(index * 22 * 3_600)),
            duration: 22 * 3_600,
            diskReadBytes: 1,
            diskWriteBytes: 1,
            networkReceiveBytes: 1,
            networkSendBytes: 1,
            averageCPUPercent: nil,
            peakCPUPercent: nil
        )
    }

    #expect(HistoryTrendChart.recommendedMinimumDuration(points: points) == 44 * 3_600)
}

@MainActor
@Test func historyChartMinimumZoomIgnoresMissingSegmentDistance() {
    let start = Date(timeIntervalSince1970: 8_000)
    let oneHour: TimeInterval = 3_600
    let points = [
        HistoryTrendPoint(timestamp: start, duration: oneHour, diskReadBytes: 1, diskWriteBytes: 1, networkReceiveBytes: 1, networkSendBytes: 1, averageCPUPercent: nil, peakCPUPercent: nil),
        HistoryTrendPoint(timestamp: start.addingTimeInterval(oneHour), duration: oneHour, diskReadBytes: 1, diskWriteBytes: 1, networkReceiveBytes: 1, networkSendBytes: 1, averageCPUPercent: nil, peakCPUPercent: nil),
        HistoryTrendPoint(timestamp: start.addingTimeInterval(30 * 86_400), duration: oneHour, diskReadBytes: 1, diskWriteBytes: 1, networkReceiveBytes: 1, networkSendBytes: 1, averageCPUPercent: nil, peakCPUPercent: nil, startsNewSegment: true),
        HistoryTrendPoint(timestamp: start.addingTimeInterval(30 * 86_400 + oneHour), duration: oneHour, diskReadBytes: 1, diskWriteBytes: 1, networkReceiveBytes: 1, networkSendBytes: 1, averageCPUPercent: nil, peakCPUPercent: nil)
    ]

    #expect(HistoryTrendChart.recommendedMinimumDuration(points: points) == 2 * oneHour)
}

@Test func historyViewportNavigatorFillsTheTrackWhenScrollingIsUnavailable() {
    let start = Date(timeIntervalSince1970: 9_000)
    var viewport = HistoryChartViewport(
        dataDomain: start...start.addingTimeInterval(1_000),
        visibleDuration: 400,
        trailingBlankFraction: 0.15
    )

    viewport.zoom(by: 100, anchor: start.addingTimeInterval(500))

    #expect(!viewport.canScroll)
    #expect(viewport.navigatorVisibleFraction == 1)
}

@Test func historyViewportPansFromTheOriginalPositionWithoutAccumulatingDragError() {
    let start = Date(timeIntervalSince1970: 10_000)
    var viewport = HistoryChartViewport(
        dataDomain: start...start.addingTimeInterval(1_000),
        visibleDuration: 200,
        trailingBlankFraction: 0.1
    )
    viewport.scroll(to: start.addingTimeInterval(400))
    let dragOrigin = viewport.scrollPosition

    viewport.pan(from: dragOrigin, horizontalTranslation: 50, plotWidth: 200)
    #expect(viewport.scrollPosition == start.addingTimeInterval(350))

    viewport.pan(from: dragOrigin, horizontalTranslation: -100, plotWidth: 200)
    #expect(viewport.scrollPosition == start.addingTimeInterval(500))
    #expect(viewport.visibleDomain.upperBound.timeIntervalSince(viewport.visibleDomain.lowerBound) == 200)
}

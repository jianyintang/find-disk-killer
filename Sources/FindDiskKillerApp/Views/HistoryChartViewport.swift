import Foundation

struct HistoryChartViewport: Equatable {
    let dataDomain: ClosedRange<Date>
    let domain: ClosedRange<Date>
    let minimumVisibleDuration: TimeInterval
    let maximumVisibleDuration: TimeInterval
    let trailingBlankFraction: Double
    private(set) var visibleDuration: TimeInterval
    private(set) var scrollPosition: Date

    init(
        dataDomain: ClosedRange<Date>,
        visibleDuration: TimeInterval,
        trailingBlankFraction: Double = 0.15,
        minimumVisibleDuration: TimeInterval = 60
    ) {
        self.dataDomain = dataDomain
        let requestedVisibleDuration = max(1, visibleDuration)
        self.trailingBlankFraction = min(0.5, max(0, trailingBlankFraction))
        let trailingDuration = requestedVisibleDuration * self.trailingBlankFraction
        let domainEnd = dataDomain.upperBound.addingTimeInterval(trailingDuration)
        domain = dataDomain.lowerBound...domainEnd

        let totalDuration = max(1, domainEnd.timeIntervalSince(dataDomain.lowerBound))
        self.minimumVisibleDuration = min(max(1, minimumVisibleDuration), totalDuration)
        maximumVisibleDuration = totalDuration
        self.visibleDuration = min(max(requestedVisibleDuration, self.minimumVisibleDuration), totalDuration)
        scrollPosition = dataDomain.lowerBound
        scrollPosition = clampedScrollPosition(domainEnd.addingTimeInterval(-self.visibleDuration))
    }

    var minimumScrollPosition: Date { domain.lowerBound }

    var maximumScrollPosition: Date {
        let domainLimit = domain.upperBound.addingTimeInterval(-visibleDuration)
        let proportionalLimit = dataDomain.upperBound.addingTimeInterval(
            -(visibleDuration * (1 - trailingBlankFraction))
        )
        return max(minimumScrollPosition, min(domainLimit, proportionalLimit))
    }

    var canScroll: Bool {
        maximumScrollPosition.timeIntervalSince(minimumScrollPosition) > 0.5
    }

    var scrollProgress: Double {
        let available = maximumScrollPosition.timeIntervalSince(minimumScrollPosition)
        guard available > 0 else { return 0 }
        return min(1, max(0, scrollPosition.timeIntervalSince(minimumScrollPosition) / available))
    }

    var navigatorVisibleFraction: Double {
        let scrollableDuration = maximumScrollPosition.timeIntervalSince(minimumScrollPosition)
        guard scrollableDuration > 0.5 else { return 1 }
        return min(1, visibleDuration / (visibleDuration + scrollableDuration))
    }

    var visibleDomain: ClosedRange<Date> {
        scrollPosition...scrollPosition.addingTimeInterval(visibleDuration)
    }

    mutating func scroll(to position: Date) {
        scrollPosition = clampedScrollPosition(position)
    }

    mutating func setProgress(_ progress: Double) {
        let available = maximumScrollPosition.timeIntervalSince(minimumScrollPosition)
        let clampedProgress = min(1, max(0, progress))
        scroll(to: minimumScrollPosition.addingTimeInterval(available * clampedProgress))
    }

    mutating func pan(
        from origin: Date,
        horizontalTranslation: Double,
        plotWidth: Double
    ) {
        guard plotWidth > 0, horizontalTranslation.isFinite else { return }
        let timeOffset = -(horizontalTranslation / plotWidth) * visibleDuration
        scroll(to: origin.addingTimeInterval(timeOffset))
    }

    mutating func zoom(by factor: Double, anchor: Date) {
        guard factor.isFinite, factor > 0 else { return }
        let oldDuration = visibleDuration
        let newDuration = min(
            maximumVisibleDuration,
            max(minimumVisibleDuration, oldDuration * factor)
        )
        guard abs(newDuration - oldDuration) > 0.5 else { return }

        let anchorRatio = min(
            1,
            max(0, anchor.timeIntervalSince(scrollPosition) / oldDuration)
        )
        visibleDuration = newDuration
        scrollPosition = clampedScrollPosition(
            anchor.addingTimeInterval(-(newDuration * anchorRatio))
        )
    }

    func nearestDate(to target: Date, candidates: [Date]) -> Date? {
        candidates.min {
            abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
        }
    }

    private func clampedScrollPosition(_ position: Date) -> Date {
        min(max(position, minimumScrollPosition), maximumScrollPosition)
    }
}

import Foundation
import Testing
@testable import FindDiskKillerApp

@Test func layerPlotPreservesGapsAndIndependentSegments() {
    let start = Date(timeIntervalSince1970: 1_000)
    let points = [
        LayerPlotPoint(date: start, value: 2, segment: 1),
        LayerPlotPoint(date: start.addingTimeInterval(1), value: 3, segment: 1),
        LayerPlotPoint(date: start.addingTimeInterval(2), value: nil, segment: 1),
        LayerPlotPoint(date: start.addingTimeInterval(3), value: 5, segment: 1),
        LayerPlotPoint(date: start.addingTimeInterval(4), value: 8, segment: 2),
        LayerPlotPoint(date: start.addingTimeInterval(5), value: .infinity, segment: 2),
        LayerPlotPoint(date: start.addingTimeInterval(6), value: 0, segment: 2)
    ]
    #expect(layerPlotSegments(points) == [Array(points[0...1]), [points[3]], [points[4]], [points[6]]])
}

@Test func layerPlotDoesNotConnectDuplicateOrReversedTimestamps() {
    let now = Date(timeIntervalSince1970: 1_000)
    let points = [
        LayerPlotPoint(date: now, value: 0, segment: 1),
        LayerPlotPoint(date: now, value: 2, segment: 1),
        LayerPlotPoint(date: now.addingTimeInterval(-1), value: 3, segment: 1)
    ]
    #expect(layerPlotSegments(points) == points.map { [$0] })
    #expect(layerPlotSegments([]).isEmpty)
}

@Test func layerPlotRetainsOnlyTheAdjacentRealSampleAtTheRollingEdge() {
    let start = Date(timeIntervalSince1970: 1_000)
    let points = (0..<4).map {
        LayerPlotPoint(date: start.addingTimeInterval(Double($0)), value: Double($0), segment: 1)
    }
    #expect(layerPlotPredecessor(previous: Array(points.prefix(3)), next: Array(points.suffix(3))) == points[0])
    #expect(layerPlotPredecessor(previous: Array(points.prefix(2)), next: Array(points.suffix(2))) == nil)
    let gap = LayerPlotPoint(date: points[0].date, value: nil, segment: 1)
    #expect(layerPlotPredecessor(previous: [gap, points[1]], next: [points[1], points[2]]) == nil)
    let otherSegment = LayerPlotPoint(date: points[0].date, value: 1, segment: 0)
    #expect(layerPlotPredecessor(previous: [otherSegment, points[1]], next: [points[1], points[2]]) == nil)
}

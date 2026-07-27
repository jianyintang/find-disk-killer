import Testing
@testable import FindDiskKillerApp

@Test func processTableKeepsBaseWidthsWhenTheContainerIsNarrow() {
    let base = ProcessColumnWidths.defaults

    let resolved = base.adapted(to: base.tableWidth - 180)

    #expect(resolved == base)
}

@Test func processTableDistributesWideSpaceWithoutOverstretchingTheApplicationColumn() {
    let base = ProcessColumnWidths.defaults
    let availableWidth = 1_520.0

    let resolved = base.adapted(to: availableWidth)

    #expect(abs(resolved.tableWidth - availableWidth) < 0.001)
    #expect(resolved[.application] <= ProcessColumn.adaptiveApplicationUpperBound)
    #expect(resolved[.application] > base[.application])
    #expect(resolved[.cpu] > base[.cpu])
    #expect(resolved[.networkDownload] > base[.networkDownload])
    #expect(resolved[.networkDownload] - base[.networkDownload]
        > resolved[.cpu] - base[.cpu])
}

@Test func processTableNeverShrinksAUserExpandedApplicationColumn() {
    var base = ProcessColumnWidths.defaults
    base[.application] = 400

    let resolved = base.adapted(to: 1_600)

    #expect(resolved[.application] >= 400)
    #expect(abs(resolved.tableWidth - 1_600) < 0.001)
}

import Testing
@testable import FindDiskKillerCore

@Test func historyApplicationAggregationPolicyKeepsDocumentedIdentityLimits() {
    #expect(HistoryApplicationAggregationPolicy.minuteApplicationLimit == 16)
    #expect(HistoryApplicationAggregationPolicy.quarterHourApplicationLimit == 32)
    #expect(HistoryApplicationAggregationPolicy.hourlyApplicationLimit == 50)
    #expect(HistoryApplicationAggregationPolicy.dailyLedgerIdentityLimit == 1_024)
}

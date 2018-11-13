import XCTest

#if !os(macOS)
public func allTests() -> [XCTestCaseEntry] {
    return [
        testCase(HDTTests.allTests),
        testCase(HDTTriplePatternMatching.allTests),
        testCase(HDTPerformanceTests.allTests),
        testCase(UtilTests.allTests)
    ]
}
#endif

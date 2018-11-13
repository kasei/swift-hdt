import XCTest
import Kineo
import Foundation
import SPARQLSyntax
@testable import HDT

final class HDTPerformanceTests: XCTestCase {
    var filename : String!
    var p : HDTParser!
    
    static var allTests = [
        ("testPerformance_ntriplesSerialization", testPerformance_ntriplesSerialization),
        ]
    
    override func setUp() {
        let datasetPath = ProcessInfo.processInfo.environment["HDT_TEST_DATASET_PATH"] ?? "/Users/greg/data/datasets"
        self.filename = "\(datasetPath)/swdf-2012-11-28.hdt"
        self.p = try! HDTParser(filename: filename)
    }
    
    func testPerformance_ntriplesSerialization() throws {
        let limit = 10_000
        let hdt = try p.parse()

        let ser = NTriplesSerializer()
        self.measure {
            do {
                let triples = try hdt.triples().prefix(limit)
                var str = ""
                try ser.serialize(triples, to: &str)
            } catch {}
        }
    }
}

import XCTest
import Foundation
import SPARQLSyntax
@testable import HDT

final class UtilTests: XCTestCase {
    static var allTests = [
        ("testBlockIterator", testBlockIterator),
        ]
    
    override func setUp() {
    }
    
    func testBlockIterator() throws {
        var data = [
            [1,2,3],
            [4,5],
            [],
            [6,7,8,9]
        ]
        
        let base = AnyIterator { () -> [Int]? in
            let block = data.first
            if !data.isEmpty {
                data.remove(at: 0)
            }
            return block
        }
        
        let i = BlockIterator(base)
        let got = Array(IteratorSequence(i))
        let expected = Array(1...9)
        XCTAssertEqual(got, expected)
    }
}

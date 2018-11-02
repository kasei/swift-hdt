import XCTest
import Foundation
import SPARQLSyntax
@testable import HDT

final class HDTTriplePatternMatching: XCTestCase {
    var filename : String!
    var p : HDTParser!
    
    static var allTests = [
        ("testTriplePatternMatch_s1", testTriplePatternMatch_s1),
        ("testTriplePatternMatch_s2", testTriplePatternMatch_s2),
        ]
    
    override func setUp() {
        self.filename = "/Users/greg/data/datasets/swdf-2012-11-28.hdt"
        self.p = try! HDTParser(filename: filename)
    }
    
    func testTriplePatternMatch_s1() throws {
        do {
            let hdt = try p.parse()
            let tp = TriplePattern(
                subject: .bound(Term(value: "b10", type: .blank)),
                predicate: .variable("p", binding: true),
                object: .variable("o", binding: true)
            )
            let triplesIterator = try hdt.triples(matching: tp)
            let triples = Array(triplesIterator)
            XCTAssertEqual(triples.count, 4)
//            for t in triples {
//                print(t)
//            }
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
    
    func testTriplePatternMatch_s2() throws {
        do {
            let hdt = try p.parse()
            let tp = TriplePattern(
                subject: .bound(Term(iri: "http://data.semanticweb.org/person/gregory-todd-williams")),
                predicate: .variable("p", binding: true),
                object: .variable("o", binding: true)
            )
            let triplesIterator = try hdt.triples(matching: tp)
            let triples = Array(triplesIterator)
            XCTAssertEqual(triples.count, 11)
//            for t in triples {
//                print(t)
//            }
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
}


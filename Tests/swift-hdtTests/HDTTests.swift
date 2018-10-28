import XCTest
import Foundation
import SPARQLSyntax
@testable import HDT

final class HDTTests: XCTestCase {
    var filename : String!
    var p : HDTMMapParser!
    
    static var allTests = [
        ("testHDTDictionary", testHDTDictionary),
        ("testHDTTriplesParse", testHDTTriplesParse),
        ("testHDTParse", testHDTParse),
        ]
    
    override func setUp() {
        self.filename = "/Users/greg/data/datasets/swdf-2012-11-28.hdt"
        self.p = try! HDTMMapParser(filename: filename)
    }
    
    let expectedTermTests : [(Int64, LookupPosition, Term)] = [
        (8, .subject, Term(value: "b5", type: .blank)),
        (9, .subject, Term(value: "b6", type: .blank)),
        (1_000, .subject, Term(iri: "http://data.semanticweb.org/conference/eswc/2006/roles/paper-presenter-semantic-web-mining-and-personalisation-hoser")),
        (76_494, .object, Term(iri: "http://xmlns.com/foaf/0.1/Person")),
        (31_100, .object, Term(string: "Alvaro")),
        (118, .predicate, Term(iri: "http://www.w3.org/2000/01/rdf-schema#label")),
        //            29_177: Term(value: "7th International Semantic Web Conference", type: .language("en")),
        //            26_183: Term(integer: 3),
    ]
    
    func testHDTDictionary() throws {
        let hdt = try p.parse()
        
        do {
            let offset : Int64 = 1819
            let termDictionary = try hdt.readDictionary(at: offset)
            XCTAssertEqual(termDictionary.count, 76881)
            
            for (id, pos, expected) in expectedTermTests {
                guard let term = try termDictionary.term(for: id, position: pos) else {
                    XCTFail("No term found for ID \(id)")
                    return
                }
                XCTAssertEqual(term, expected)
            }
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
    
    func testHDTTriplesParse() throws {
        let hdt = try p.parse()
        
        let expectedPrefix : [(Int64, Int64, Int64)] = [
            (1, 90, 13304),
            (1, 101, 19384),
            (1, 111, 75817),
            (2, 90, 19470),
            (2, 101, 13049),
            (2, 104, 13831),
            (2, 111, 75817),
            ]
        let triples : AnyIterator<(Int64, Int64, Int64)> = try hdt.readTriples(at: 5159548)
        let gotPrefix = Array(triples.prefix(expectedPrefix.count))
        for (i, d) in zip(gotPrefix, expectedPrefix).enumerated() {
            let (g, e) = d
            print("got triple: \(g)")
            XCTAssertEqual(g.0, e.0)
            XCTAssertEqual(g.1, e.1)
            XCTAssertEqual(g.2, e.2)
        }
    }
    
    func testHDTTriples() throws {
        do {
            let triples = try p.triples(from: filename)
            guard let t = triples.next() else {
                XCTFail()
                return
            }
            print(t)
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
    
    func testHDTParse() throws {
        do {
            let hdt = try p.parse()
            let triples = try hdt.triples()
            guard let t = triples.next() else {
                XCTFail()
                return
            }
            print("t: \(t)")
            XCTAssertEqual(t.subject, Term(value: "b1", type: .blank))
            XCTAssertEqual(t.predicate, Term(iri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#_1"))
            XCTAssertEqual(t.object, Term(iri: "http://data.semanticweb.org/person/barry-norton"))
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
}


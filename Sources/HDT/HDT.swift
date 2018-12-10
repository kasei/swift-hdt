import Foundation
import SPARQLSyntax

#if os(macOS)
import os.log
import os.signpost
#endif

public enum HDTError: Error {
    case error(String)
}

public struct HeaderMetadata: CustomDebugStringConvertible {
    var controlInformation: HDT.ControlInformation
    var rdfContent: String
    var offset: off_t
    
    public var debugDescription: String {
        var s = ""
        print(controlInformation, to: &s)
        print("offset: \(offset)", to: &s)
        print("rdf payload:\n\(rdfContent)", to: &s)
        // If we wanted to have Kineo be a dependency, we could pretty-print the payload:
//        do {
//            let par = RDFParser(syntax: .turtle, base: "", produceUniqueBlankIdentifiers: false)
//            var triples = [Triple]()
//            try par.parse(string: rdfContent) { (s, p, o) in
//                triples.append(Triple(subject: s, predicate: p, object: o))
//            }
//            let prefixes = [
//                "hdt": Term(iri: "http://purl.org/HDT/hdt#"),
//                "dc": Term(iri: "http://purl.org/dc/terms/"),
//                "void": Term(iri: "http://rdfs.org/ns/void#"),
//                ]
//
//            let ser = TurtleSerializer(prefixes: prefixes)
//            try ser.serialize(triples, to: &s)
//        } catch let error {
//            print("*** Failed to parse header RDF: \(error)", to: &s)
//        }
        return s
    }
}

public class HDT {
    public typealias TermID = Int64
    public typealias IDTriple = (TermID, TermID, TermID)
    
    var filename: String
    var header: HeaderMetadata
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer

    public var state: FileState
    public var simplifyBlankNodeIdentifiers: Bool
    public var controlInformation: ControlInformation

    #if os(macOS)
    let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
    #endif

    public struct ControlInformation: CustomDebugStringConvertible {
        public enum ControlType : UInt8 {
            case unknown = 0
            case global = 1
            case header = 2
            case dictionary = 3
            case triples = 4
            case index = 5
        }
        
        var type: ControlType
        var format: String
        var properties: [String:String]
        var crc: UInt16
        
        var triplesCount: Int? {
            guard let countNumber = properties["numTriples"], let count = Int(countNumber) else {
                return nil
            }
            return count
        }
        
        var tripleOrdering: TripleOrdering? {
            guard let orderNumber = properties["order"], let i = Int(orderNumber), let order = TripleOrdering(rawValue: i) else {
                return nil
            }
            return order
        }
        
        public var debugDescription: String {
            return """
            ControlInformation(
                type: .\(type),
                format: "\(format)",
                properties: \(properties),
                crc: \(String(format: "0x%02x", crc))
            )
            """
        }
    }
    
    init(filename: String, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer, control ci: ControlInformation, header: HeaderMetadata, triples: TriplesMetadata, dictionary: DictionaryMetadata) throws {
        self.filename = filename
        self.size = size
        self.mmappedPtr = mmappedPtr
        self.header = header
        self.triplesMetadata = triples
        self.dictionaryMetadata = dictionary
        self.controlInformation = ci
        self.simplifyBlankNodeIdentifiers = false
        
        self.state = .none
    }
    
    deinit {
        munmap(mmappedPtr, size)
    }
    
    func term(for id: Int64, position: LookupPosition) throws -> Term? {
        let dictionary = try hdtDictionary()
        return try dictionary.term(for: id, position: position)
    }
    
    func id(for term: Term, position: LookupPosition) throws -> Int64? {
        let dictionary = try hdtDictionary()
        return try dictionary.id(for: term, position: position)
    }

    func triplesSection() throws -> HDTTriples {
        switch self.triplesMetadata.format {
        case .bitmap:
            let t = try HDTBitmapTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
            return t
        case .list:
            let t = try HDTListTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
            return t
        }
    }
    
    func readIDTriples(at offset: off_t, dictionary: HDTDictionaryProtocol, restrict restriction: IDRestriction) throws -> (Int64, AnyIterator<IDTriple>) {
        
        switch self.triplesMetadata.format {
        case .bitmap:
            guard let t = try triplesSection() as? HDTBitmapTriples else {
                throw HDTError.error("Unexpected triples section type in readIDTriples")
            }
            let ids = dictionary.idSequence(for: .subject) // TODO: this should be based on the first position in the HDT ordering
            let (count, triples) = try t.idTriples(ids: ids, restrict: restriction)
            return (count, triples)
        case .list:
            guard let t = try triplesSection() as? HDTListTriples else {
                throw HDTError.error("Unexpected triples section type in readIDTriples")
            }
            return try t.idTriples(restrict: restriction)
        }
    }

    func readDictionary(at offset: off_t) throws -> HDTDictionaryProtocol {
        switch dictionaryMetadata.type {
        case .fourPart:
            let d = try HDTLazyFourPartDictionary(metadata: dictionaryMetadata, size: size, ptr: mmappedPtr)
            return d
        }
    }
}

extension HDT: CustomDebugStringConvertible {
    public var debugDescription: String {
        do {
            var s = ""
            print("HDT:", to: &s)
            print(controlInformation, to: &s)
            print("", to: &s)
            
            print("Header:", to: &s)
            print(header, to: &s)

            print("Dictionary:", to: &s)
            let dictionary = try hdtDictionary()
            print(dictionary, to: &s)
            print("", to: &s)
            
            print("Triples:", to: &s)
            let t = try triplesSection()
            print(t, to: &s)
            
            return s
        } catch {
            return "(*** error describing HDT ***)"
        }
    }
}

public extension HDT {
    private class HDTTriplesIterator<I: IteratorProtocol>: IteratorProtocol where I.Element == Triple {
        var hdt: HDT
        var triples: I
        
        init(hdt: HDT, triples: I) {
            self.hdt = hdt
            self.triples = triples
        }
        
        func next() -> Triple? {
            return triples.next()
        }
    }
    
    func hdtDictionary() throws -> HDTDictionaryProtocol {
        var dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        dictionary.simplifyBlankNodeIdentifiers = self.simplifyBlankNodeIdentifiers
        return dictionary
    }
    
    // TODO: add code to support loading directly into a kineo model using:
    //           MemoryQuadStore.load(version:dictionary:quads:)
    //       materialize predicates and then re-map subjects/objects that
    //       appear as predicates to their predicate ID values.
    //       use high bits to separate ID spaces of predicates and subject/objects
    
    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try hdtDictionary()
        #if os(macOS)
        os_signpost(.begin, log: log, name: "Triples", "Read ID Triples")
        #endif
        let (_, tripleIDs) = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: (nil, nil, nil))
        #if os(macOS)
        os_signpost(.end, log: log, name: "Triples", "Read ID Triples")
        #endif

        #if os(macOS)
        os_signpost(.begin, log: log, name: "Triples", "Materializing")
        #endif
        let triples = tripleIDs.lazy.compactMap { self.mapToTriple(ids: $0, from: dictionary) }
        #if os(macOS)
        os_signpost(.end, log: log, name: "Triples", "Materializing")
        #endif

        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    private func mapToTriple(ids t: IDTriple, from dictionary: HDTDictionaryProtocol) -> Triple? {
        do {
            guard let s = try dictionary.term(for: t.0, position: .subject) else {
                warn("failed to load term for subject \(t.0)")
                return nil
            }
            guard let p = try dictionary.term(for: t.1, position: .predicate) else {
                warn("failed to load term for predicate \(t.1)")
                return nil
            }
            guard let o = try dictionary.term(for: t.2, position: .object) else {
                warn("failed to load term for object \(t.2)")
                return nil
            }
            return Triple(subject: s, predicate: p, object: o)
        } catch let error {
            warn(">>> error mapping IDs to triple: \(error)")
            return nil
        }
    }
    
    private func triples(dictionary: HDTDictionaryProtocol, restrict restriction: IDRestriction) throws -> AnyIterator<Triple> {
        let order = self.triplesMetadata.ordering
        guard case .spo = order else {
            throw HDTError.error("TriplePattern matching on non-SPO ordered triples is unimplemented") // TODO
        }
        let (_, tripleIDs) = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: restriction)
        let triples = tripleIDs.lazy
            .filter {
                if let s = restriction.0, s != $0.0 {
                    return false
                }
                if let p = restriction.1, p != $0.1 {
                    return false
                }
                if let o = restriction.2, o != $0.2 {
                    return false
                }
                return true
            }
            .compactMap { self.mapToTriple(ids: $0, from: dictionary) }

        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    public func triples(matching tp: TriplePattern) throws -> AnyIterator<Triple> {
        let dictionary = try hdtDictionary()
        
        var restrictions = [LookupPosition:Int64]()
        var variables = [LookupPosition:String]()
        
        let pairs = zip([LookupPosition.subject, .predicate, .object], tp)
        for  (pos, node) in pairs {
            switch node {
            case .bound(let term):
                if let id = try dictionary.id(for: term, position: pos) {
                    restrictions[pos] = id
                } else {
                    return AnyIterator([].makeIterator())
                }
            case .variable(let name, binding: _):
                variables[pos] = name
            }
        }

        let order = self.triplesMetadata.ordering
        guard case .spo = order else {
            throw HDTError.error("TriplePattern matching on non-SPO ordered triples is unimplemented") // TODO: ensure the restriction tuples below are properly ordered for the current HDT ordering
        }
        
        let boundPositions = Set(restrictions.keys)
        switch boundPositions {
        case [.subject]:
            let x = restrictions[.subject]!
            return try triples(dictionary: dictionary, restrict: (x, nil, nil))
        case [.subject, .predicate]:
            let x = restrictions[.subject]!
            let y = restrictions[.predicate]!
            return try triples(dictionary: dictionary, restrict: (x, y, nil))
        case [.subject, .predicate, .object]:
            let x = restrictions[.subject]!
            let y = restrictions[.predicate]!
            let z = restrictions[.object]!
            return try triples(dictionary: dictionary, restrict: (x, y, z))
        case []:
            return try triples()
        default:
            throw HDTError.error("TriplePattern matching cannot be performed on a pattern that requires an index other than \(order)")
        }
    }
}

public class HDTRDFParser: RDFParser {
    public enum Error: Swift.Error {
        case invalid
    }
    
    public var mediaTypes: Set<String>
    public static var canonicalMediaType = "application/hdt"
    public static var canonicalFileExtensions = [".hdt"]
    required public init() {
        mediaTypes = [HDTRDFParser.canonicalMediaType]
    }
    
//    public static func register() {
//        RDFSerializationConfiguration.shared.registerParser(self, withType: HDTRDFParser.canonicalMediaType, extensions: HDTRDFParser.canonicalFileExtensions, mediaTypes: [])
//    }
    
    public func parse(string: String, mediaType: String, base: String? = nil, handleTriple: @escaping TripleHandler) throws -> Int {
        throw Error.invalid
    }
    
    public func parseFile(_ filename: String, mediaType: String, base: String? = nil, handleTriple: @escaping TripleHandler) throws -> Int {
        let p = try HDTParser(filename: filename)
        let hdt = try p.parse()
        let triples = try hdt.triples()
        var count = 0
        for t in triples {
            handleTriple(t.subject, t.predicate, t.object)
            count += 1
        }
        return count
    }
}

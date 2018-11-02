import Darwin
import Foundation
import SPARQLSyntax

public enum HDTError: Error {
    case error(String)
}

public class HDT {
    public typealias TermID = Int64
    public typealias IDTriple = (TermID, TermID, TermID)
    
    var filename: String
    var header: String
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    public var state: FileState
    var soCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var pCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer

    init(filename: String, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer, header: String, triples: TriplesMetadata, dictionary: DictionaryMetadata) throws {
        self.filename = filename
        self.size = size
        self.mmappedPtr = mmappedPtr
        self.header = header
        self.triplesMetadata = triples
        self.dictionaryMetadata = dictionary
        self.state = .none
    }
    
    deinit {
        munmap(mmappedPtr, size)
    }
    
    func term(for id: Int64, position: LookupPosition) throws -> Term? {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        return try dictionary.term(for: id, position: position)
    }
    
    func id(for term: Term, position: LookupPosition) throws -> Int64? {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        return try dictionary.id(for: term, position: position)
    }

    func readIDTriples(at offset: off_t, dictionary: HDTDictionaryProtocol, restrict restriction: IDRestriction) throws -> AnyIterator<IDTriple> {
        switch self.triplesMetadata.format {
        case .bitmap:
            let ids = dictionary.idSequence(for: .subject) // TODO: this should be based on the first position in the HDT ordering
            let t = try HDTBitmapTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
            let triples = try t.idTriples(ids: ids, restrict: restriction)
            return triples
        case .list:
            let t = try HDTListTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
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


public extension HDT {
    private class HDTTriplesIterator<I: IteratorProtocol>: IteratorProtocol where I.Element == Triple {
        typealias Element = Triple
        
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

    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        let tripleIDs = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: (nil, nil, nil))
        let triples = tripleIDs.lazy.compactMap { self.mapToTriple(ids: $0, from: dictionary) }
        
        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    private func mapToTriple(ids t: IDTriple, from dictionary: HDTDictionaryProtocol) -> Triple? {
        do {
            guard let s = try dictionary.term(for: t.0, position: .subject) else {
                return nil
            }
            guard let p = try dictionary.term(for: t.1, position: .predicate) else {
                return nil
            }
            guard let o = try dictionary.term(for: t.2, position: .object) else {
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
        let tripleIDs = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: restriction)
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
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        
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
            throw HDTError.error("TriplePattern matching on non-SPO ordered triples is unimplemented") // TODO
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
            fatalError("TriplePattern matching cannot be performed on a pattern that requires an index other than \(order)")
        }
        
        fatalError("unimplemented")
    }
}

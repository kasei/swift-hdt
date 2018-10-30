import Darwin
import Foundation
import SPARQLSyntax

public enum HDTError: Error {
    case error(String)
}

public class HDT {
    var filename: String
    var header: String
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    public var state: FileState
    var soCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var pCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer

    private class HDTTriplesIterator: IteratorProtocol {
        typealias Element = Triple
        
        var hdt: HDT
        var triples: LazyMapSequence<LazyFilterSequence<LazyMapSequence<AnyIterator<(Int64, Int64, Int64)>, Triple?>>, Triple>.Iterator
        
        init(hdt: HDT, triples: LazyMapSequence<LazyFilterSequence<LazyMapSequence<AnyIterator<(Int64, Int64, Int64)>, Triple?>>, Triple>.Iterator) {
            self.hdt = hdt
            self.triples = triples
        }
        
        func next() -> Triple? {
            return triples.next()
        }
    }
    
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
    
    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        let tripleIDs = try readTriples(at: self.triplesMetadata.offset, dictionary: dictionary)
        let triples = tripleIDs.lazy.compactMap { t -> Triple? in
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
                print(">>> \(error)")
                return nil
            }
        }
        
        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    func generateTriples<S: Sequence>(data: BitmapTriplesData, topLevelIDs gen: S) throws -> AnyIterator<(Int64, Int64, Int64)> where S.Element == Int64 {
        let order = self.triplesMetadata.ordering
        
        let y = data.arrayY.makeIterator()
        let z = data.arrayZ.makeIterator()
        let pairs = generatePairs(elements: gen.makeIterator(), index: data.bitmapY, array: y)
        let triplets = generatePairs(elements: pairs, index: data.bitmapZ, array: z)

        switch order {
        case .spo:
            let triples = triplets.lazy.map { ($0.0.0, $0.0.1, $0.1) }
            return AnyIterator(triples.makeIterator())
        case .sop:
            let triples = triplets.lazy.map { ($0.0.0, $0.1, $0.0.1) }
            return AnyIterator(triples.makeIterator())
        case .pso:
            let triples = triplets.lazy.map { ($0.0.1, $0.0.0, $0.1) }
            return AnyIterator(triples.makeIterator())
        case .pos:
            let triples = triplets.lazy.map { ($0.1, $0.0.0, $0.0.0) }
            return AnyIterator(triples.makeIterator())
        case .osp:
            let triples = triplets.lazy.map { ($0.0.1, $0.1, $0.0.0) }
            return AnyIterator(triples.makeIterator())
        case .ops:
            let triples = triplets.lazy.map { ($0.1, $0.0.1, $0.0.0) }
            return AnyIterator(triples.makeIterator())
        case .unknown:
            throw HDTError.error("Cannot parse bitmap triples block with unknown ordering")
        }
    }
    
    func readTriples(at offset: off_t, dictionary: HDTDictionaryProtocol) throws -> AnyIterator<(Int64, Int64, Int64)> {
        switch self.triplesMetadata.format {
        case .bitmap:
            let (data, _) = try readTriplesBitmap(at: self.triplesMetadata.offset)
            let ids = dictionary.idSequence(for: .subject) // TODO: this should be based on the first position in the HDT ordering
            let triples = try generateTriples(data: data, topLevelIDs: ids)
            return triples
        case .list:
            fatalError("TODO: Reading list-based triples currently unimplemented")
        }
    }
    
    func generatePairs<I: IteratorProtocol, J: IteratorProtocol, C: IteratorProtocol>(elements: I, index _bits: J, array: C) -> AnyIterator<(I.Element, C.Element)> where J.Element == Int {
        var bits = PeekableIterator(generator: _bits)
        var currentIndex = 0
        var elements = elements
        var arrayIterator = array

        var buffer = [(I.Element, C.Element)]()
        let gen = { () -> (I.Element, C.Element)? in
            repeat {
                if !buffer.isEmpty {
                    return buffer.remove(at: 0)
                }
                guard let next = elements.next() else {
                    return nil
                }
                
                // let k = count the number of elements in $index up to (and including) the next 1
                var k = 0
                repeat {
                    k += 1
                    currentIndex += 1
                    
                    if let next = bits.peek() {
                        if next == (currentIndex - 1) {
                            _ = bits.next()
                            break
                        }
                    } else {
                        break
                    }
                } while true

                for _ in 0..<k {
                    if let item = arrayIterator.next() {
                        buffer.append((next, item))
                    }
                }
            } while true
        }
        return AnyIterator(gen)
    }
    
    func readTriplesBitmap(at offset: off_t) throws -> (BitmapTriplesData, Int64) {
        let (bitmapY, byLength) = try readBitmap(from: mmappedPtr, at: offset)
        let (bitmapZ, bzLength) = try readBitmap(from: mmappedPtr, at: offset + byLength)
        let (arrayY, ayLength) = try readArray(from: mmappedPtr, at: offset + byLength + bzLength)
        let (arrayZ, azLength) = try readArray(from: mmappedPtr, at: offset + byLength + bzLength + ayLength)
        
        let length = byLength + bzLength + ayLength + azLength
        let data = BitmapTriplesData(bitmapY: bitmapY, bitmapZ: bitmapZ, arrayY: arrayY, arrayZ: arrayZ)
        return (data, length)
    }
    
    func readDictionary(at offset: off_t) throws -> HDTDictionaryProtocol {
        switch dictionaryMetadata.type {
        case .fourPart:
            let d = try HDTLazyFourPartDictionary(metadata: dictionaryMetadata, size: size, ptr: mmappedPtr)
            return d
        }
    }
}


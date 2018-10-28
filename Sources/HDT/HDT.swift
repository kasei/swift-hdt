import Darwin
import Foundation
import SPARQLSyntax

public enum HDTError: Error {
    case error(String)
}

public class MemoryMappedHDT {
    var filename: String
    var header: String
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    public var state: FileState
    var soCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var pCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer

    private class MemoryMappedHDTTriplesIterator: IteratorProtocol {
        typealias Element = Triple
        
        var hdt: MemoryMappedHDT
        var triples: LazyMapSequence<LazyFilterSequence<LazyMapSequence<AnyIterator<(Int64, Int64, Int64)>, Triple?>>, Triple>.Iterator
        
        init(hdt: MemoryMappedHDT, triples: LazyMapSequence<LazyFilterSequence<LazyMapSequence<AnyIterator<(Int64, Int64, Int64)>, Triple?>>, Triple>.Iterator) {
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
    
    func term(for id: Int64, position: LookupPosition) -> Term? {
        fatalError("XXX")
    }
    
    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        let tripleIDs = try readTriples(at: self.triplesMetadata.offset)
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
            } catch {
                return nil
            }
        }
        
        let i = MemoryMappedHDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    func generateTriples<S: Sequence>(data: BitmapTriplesData, topLevelIDs gen: S) throws -> AnyIterator<(Int64, Int64, Int64)> where S.Element == Int64 {
        let order = self.triplesMetadata.ordering
        
        switch order {
        case .spo:
            let pairs = generatePairs(elements: gen.makeIterator(), index: data.bitmapY, array: data.arrayY)
            let triplets = generatePairs(elements: pairs, index: data.bitmapZ, array: data.arrayZ)
            let triples = triplets.lazy.map {
                ($0.0.0, $0.0.1, $0.1)
            }
            
            return AnyIterator(triples.makeIterator())
        case .unknown:
            throw HDTError.error("Cannot parse bitmap triples block with unknown ordering")
        default:
            fatalError("TODO: Reading \(order)-ordered triples currently unimplemented")
        }
    }
    
    
    func readTriples(at offset: off_t) throws -> AnyIterator<(Int64, Int64, Int64)> {
        warn("reading triples at offset \(offset)")
        var readBuffer = mmappedPtr + Int(offset)
        
        switch self.triplesMetadata.format {
        case .bitmap:
            let (data, length) = try readTriplesBitmap(at: self.triplesMetadata.offset)
            let gen = sequence(first: Int64(1)) { $0 + 1 } // TODO: this isn't right; this data needs to come from the dictionary
            let triples = try generateTriples(data: data, topLevelIDs: gen)
            return triples
        case .list:
            fatalError()
            //            return try readTriplesList(at: self.triples.offset, controlInformation: info)
        }
    }
    
    func generatePairs<I: IteratorProtocol, E>(elements: I, index bits: IndexSet, array: [E]) -> AnyIterator<(I.Element, E)> {
        var data = [(I.Element, E)]()
        var currentIndex = 0
        var elements = elements
        var array = array
        let gen = { () -> (I.Element, E)? in
            repeat {
                if !data.isEmpty {
                    //                    warn("- removing element from pending array of size \(data.count)")
                    return data.remove(at: 0)
                }
                guard let next = elements.next() else {
                    return nil
                }
                guard !array.isEmpty else {
                    return nil
                }
                // let k = count the number of elements in $index up to (and including) the next 1
                var k = 0
                let max = array.count
                repeat {
                    k += 1
                    currentIndex += 1
                    if k >= max {
                        break
                    }
                } while !bits.contains(currentIndex-1)
                
                //                warn("k=\(k)")
                //                warn("index set: \(bits)")
                
                let pairs = array.prefix(k).map { (next, $0) }
                array.removeFirst(k)
                //                warn("+ adding pending results x \(pairs.count)")
                data.append(contentsOf: pairs)
            } while true
        }
        return AnyIterator(gen)
    }
    
    func readTriplesBitmap(at offset: off_t) throws -> (BitmapTriplesData, Int64) {
        var readBuffer = mmappedPtr + Int(offset)
        
        warn("bitmap triples at \(offset)")
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
            warn("using lazy dictionary")
            let d = try MemoryMappedHDTLazyFourPartDictionary(metadata: dictionaryMetadata, size: size, ptr: mmappedPtr)
//            let d = try HDTLazyFourPartDictionary(metadata: dictionaryMetadata, state: state)
            //                d.forEach { (pos, id, term) in
            //                    print("term >>> \(pos) \(id) \(term)")
            //                }
            return d
        default:
            throw HDTError.error("unimplemented dictionary format type: \(dictionaryMetadata.type)")
        }
    }
}


import Foundation

public typealias IDRestriction = (HDT.TermID?, HDT.TermID?, HDT.TermID?)

struct BitmapTriplesData {
    var bitmapY : BlockIterator<Int>
    var bitmapZ : BlockIterator<Int>
    var arrayY : AnySequence<Int64>
    var arrayZ : AnySequence<Int64>
}

public enum TripleOrdering: Int, CustomStringConvertible {
    case unknown = 0
    case spo = 1
    case sop = 2
    case pso = 3
    case pos = 4
    case osp = 5
    case ops = 6
    
    public var description : String {
        let ordering = ["unknown", "SPO", "SOP", "PSO", "POS", "OSP", "OPS"]
        return ordering[rawValue]
    }
}

public struct TriplesMetadata: CustomDebugStringConvertible {
    enum Format {
        case bitmap
        case list
    }
    
    var controlInformation: HDT.ControlInformation
    var format: Format
    var ordering: TripleOrdering
    var count: Int?
    var offset: off_t
    
    public var debugDescription: String {
        var s = ""
        print(controlInformation, to: &s)
        print("offset: \(offset)", to: &s)
        print("format: .\(format)", to: &s)
        print("order: <\(ordering)>", to: &s)
        if let count = count {
            print("count: \(count)", to: &s)
        }
        return s
    }
}

func generatePairs<I: IteratorProtocol, J: IteratorProtocol, C: IteratorProtocol>(elements: I, index _bits: J, array: C, startingElementOffset: Int = 0, verbose: Bool = false) -> AnyIterator<(I.Element, C.Element)> where J.Element == Int {
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
                } else {
                    if buffer.isEmpty {
                        return nil
                    } else {
                        break
                    }
                }
            }
        } while true
    }
    return AnyIterator(gen)
}

public protocol HDTTriples: CustomDebugStringConvertible {
    var metadata: TriplesMetadata { get }
    init(metadata: TriplesMetadata, size: Int, ptr: UnsafeMutableRawPointer) throws
}

public final class HDTListTriples: HDTTriples {
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    public var metadata: TriplesMetadata

    public init(metadata: TriplesMetadata, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer) throws {
        self.metadata = metadata
        self.mmappedPtr = mmappedPtr
        self.size = size
    }

    func generateListTriples(at offset: off_t, triples count: Int) throws -> AnyIterator<HDT.IDTriple> {
        // TODO: move this code to its own class HDTListTriples in Triples.swift
        let readBuffer = mmappedPtr + Int(offset)
        let p = readBuffer.assumingMemoryBound(to: UInt32.self)
        
        let buffer = UnsafeBufferPointer(start: p, count: 3*count)
        let s = stride(from: buffer.startIndex, to: buffer.endIndex, by: 3)
        let t = s.lazy.map { (Int64(buffer[$0]), Int64(buffer[$0+1]), Int64(buffer[$0+2])) }
        
        let ptr = readBuffer + (4*3*count)
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        
        return AnyIterator(t.makeIterator())
    }

    public func idTriples(restrict restriction: IDRestriction) throws -> (Int64, AnyIterator<HDT.IDTriple>) {
        guard let count = metadata.count else {
            throw HDTError.error("Cannot parse list triples because no numTriples property value was found")
        }
        let t = try generateListTriples(at: metadata.offset, triples: count)
        return (Int64(count), t)
    }
}

extension HDTListTriples: CustomDebugStringConvertible {
    public var debugDescription: String {
        var s = ""
        print(metadata, terminator: "", to: &s)
        do {
            let (count, i) = try idTriples(restrict: (nil, nil, nil))
            print("parsed triple count: \(count)", to: &s)
//            var actual = 0
//            for _ in IteratorSequence(i) {
//                actual += 1
//            }
//            print("actual ID triple count: \(actual)", to: &s)
        } catch {
            warn(error)
        }
        return s
    }
}

public final class HDTBitmapTriples: HDTTriples {
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    public var metadata: TriplesMetadata
    
    public init(metadata: TriplesMetadata, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer) throws {
        self.metadata = metadata
        self.mmappedPtr = mmappedPtr
        self.size = size
    }
    
    func readTriplesBitmap() throws -> (BitmapTriplesData, Int64, Int64) {
        let offset = metadata.offset
        let (bitmapY, _, byLength) = try readBitmap(from: mmappedPtr, at: offset)
        let (bitmapZ, zBitCount, bzLength) = try readBitmap(from: mmappedPtr, at: offset + off_t(byLength))
        let (arrayY, ayLength) = try readArray(from: mmappedPtr, at: offset + off_t(byLength) + off_t(bzLength))
        let (arrayZ, azLength) = try readArray(from: mmappedPtr, at: offset + off_t(byLength) + off_t(bzLength) + off_t(ayLength))
        
        let length = byLength + bzLength + ayLength + azLength
        let data = BitmapTriplesData(bitmapY: bitmapY, bitmapZ: bitmapZ, arrayY: arrayY, arrayZ: arrayZ)
        return (data, zBitCount, length)
    }
    
    func generateBitmapTriples<S: Sequence>(data: BitmapTriplesData, topLevelIDs gen: S, restrict restriction: IDRestriction) throws -> AnyIterator<HDT.IDTriple> where S.Element == Int64 {
        let order = metadata.ordering
        
        let x = AnyIterator(gen.makeIterator())
        
        // OPTIMIZE: skip data if there are restrictions
        let y = data.arrayY.makeIterator()
        let bitmapY = data.bitmapY
        let z = data.arrayZ.makeIterator()
        let bitmapZ = data.bitmapZ
        
        let pairs = generatePairs(elements: x, index: bitmapY, array: y)
        let triplets = generatePairs(elements: pairs, index: bitmapZ, array: z)
        
        var triplesIterator : AnyIterator<HDT.IDTriple>
        switch order {
        case .spo:
            let triples = triplets.lazy.map { ($0.0.0, $0.0.1, $0.1) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .sop:
            let triples = triplets.lazy.map { ($0.0.0, $0.1, $0.0.1) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .pso:
            let triples = triplets.lazy.map { ($0.0.1, $0.0.0, $0.1) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .pos:
            let triples = triplets.lazy.map { ($0.1, $0.0.0, $0.0.0) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .osp:
            let triples = triplets.lazy.map { ($0.0.1, $0.1, $0.0.0) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .ops:
            let triples = triplets.lazy.map { ($0.1, $0.0.1, $0.0.0) }
            triplesIterator = AnyIterator(triples.makeIterator())
        case .unknown:
            throw HDTError.error("Cannot parse bitmap triples block with unknown ordering")
        }
        
        //        if let xr = xRestrictions {
        //            print("applying post-restriction on the X values: \(xr)")
        //            triplesIterator = triplesIterator.prefix { $0.0 == xr }.makeIterator()
        //            if let yr = yRestrictions {
        //                print("applying post-restriction on the Y values: \(yr)")
        //                triplesIterator = triplesIterator.prefix { $0.1 == yr }.makeIterator()
        //                if let zr = zRestrictions {
        //                    print("applying post-restriction on the Z values: \(zr)")
        //                    triplesIterator = triplesIterator.prefix { $0.2 == zr }.makeIterator()
        //                }
        //            }
        //        }
        
        return triplesIterator
    }
    
    public func idTriples<S: Sequence>(ids: S, restrict restriction: IDRestriction) throws -> (Int64, AnyIterator<HDT.IDTriple>) where S.Element == HDT.TermID {
        let (data, count, _) = try self.readTriplesBitmap()
        let t = try self.generateBitmapTriples(data: data, topLevelIDs: ids, restrict: restriction)
        return (count, t)
    }
}

extension HDTBitmapTriples: CustomDebugStringConvertible {
    public var debugDescription: String {
        var s = ""
        print(metadata, terminator: "", to: &s)
        do {
            let ids = (0...).lazy.map { HDT.TermID($0) }
            let (count, i) = try self.idTriples(ids: ids, restrict: (nil, nil, nil))
            print("z-bitmap triple count: \(count)", to: &s)
//            var actual = 0
//            for _ in IteratorSequence(i) {
//                actual += 1
//            }
//            print("actual triple count: \(actual)", to: &s)
        } catch {
            warn(error)
        }
        return s
    }
}


import Darwin
import Foundation
import SPARQLSyntax

public enum FileState {
    case none
    case opened(CInt)
}

public protocol FileBased {
    var state: FileState { get set }
}

extension FileBased {
    func readData(at offset: off_t, length: Int) throws -> Data {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        var size = 1024
        while size < length {
            size *= 2
        }
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r >= length else { throw HDTError.error("Not enough bytes read for data at offset \(offset)") }
        let data = Data(bytes: readBuffer, count: length)
        return data
    }

    func readBitmap(at offset: off_t) throws -> (IndexSet, Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = p[0]
        let typeLength = 1
        guard type == 1 else {
            throw HDTError.error("Invalid bitmap type (\(type)) at offset \(offset)")
        }
        
        var ptr = readBuffer + typeLength
        let bitCount = Int(readVByte(&ptr))
        let bytes = (bitCount + 7)/8
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        // TODO: verify crc
        ptr += 1
        
        let data = Data(bytes: ptr, count: bytes)
        var i = IndexSet()
        for (shift, b) in data.enumerated() {
            let add = shift*8
            if (b & 0x01) > 0 { i.insert(0 + add) }
            if (b & 0x02) > 0 { i.insert(1 + add) }
            if (b & 0x04) > 0 { i.insert(2 + add) }
            if (b & 0x08) > 0 { i.insert(3 + add) }
            if (b & 0x10) > 0 { i.insert(4 + add) }
            if (b & 0x20) > 0 { i.insert(5 + add) }
            if (b & 0x40) > 0 { i.insert(6 + add) }
            if (b & 0x80) > 0 { i.insert(7 + add) }
        }
        ptr += bytes
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        ptr += 4
        
        let length = Int64(readBuffer.distance(to: ptr))
        return (i, length)
    }

    func readArray(at offset: off_t) throws -> ([Int64], Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = p[0]
        
        switch type {
        case 1:
            let (blocks, blocksLength) = try readSequence(at: offset, assertType: 1)
            let array = blocks.map { Int64($0) }
            warn("array prefix: \(array.prefix(32))")
            return (array, blocksLength)
        case 2:
            fatalError("TODO: Array read unimplemented: uint32")
        case 3:
            fatalError("TODO: Array read unimplemented: uint64")
        default:
            throw HDTError.error("Invalid array type (\(type)) at offset \(offset)")
        }
    }

    func readSequence(at offset: off_t, assertType: UInt8? = nil) throws -> (AnySequence<Int>, Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 64 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        var r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary sequence") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let typeLength: Int
        if let assertType = assertType {
            let type = p[0]
            typeLength = 1
            guard type == assertType else {
                throw HDTError.error("Invalid dictionary LogSequence2 type (\(type)) at offset \(offset)")
            }
            warn("Sequence type: \(type)")
        } else {
            typeLength = 0
        }
        
        let bits = Int(p[typeLength])
        let bitsLength = 1
        warn("Sequence bits: \(bits)")
        
        var ptr = readBuffer + typeLength + bitsLength
        let entriesCount = Int(readVByte(&ptr))
        warn("Sequence entries: \(entriesCount)")
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        // TODO: verify crc
        ptr += 1
        
        let arraySize = (bits * entriesCount + 7) / 8
        warn("Array size for log sequence: \(arraySize)")
        let sequenceDataOffset = Int64(readBuffer.distance(to: ptr))
        warn("Offset for log sequence: \(sequenceDataOffset)")
        
        let sequenceData = try readData(at: offset + sequenceDataOffset, length: arraySize)
        ptr += arraySize
        
        var values = [Int](reserveCapacity: entriesCount)
        for i in 0..<entriesCount {
            let value = sequenceData.getField(i, width: bits)
            values.append(value)
        }
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        ptr += 4
        
        let length = Int64(readBuffer.distance(to: ptr))
        
        let seq = AnySequence(values)
        return (seq, length)
    }
}

func readVByte(_ ptr : inout UnsafeMutableRawPointer) -> UInt {
    var p = ptr.assumingMemoryBound(to: UInt8.self)
    var value : UInt = 0
    var cont = true
    var shift = 0
    repeat {
        let b = p[0]
        let bvalue = UInt(b & 0x7f)
        cont = ((b & 0x80) == 0)
        //            warn("vbyte: \(String(format: "0x%02x", b)), byte value=\(bvalue), continue=\(cont)")
        p += 1
        value += bvalue << shift;
        shift += 7
    } while cont
    let bytes = ptr.distance(to: p)
    //        warn("read \(bytes) bytes to produce value \(value)")
    ptr = UnsafeMutableRawPointer(p)
    return value
}


public enum HDTError: Error {
    case error(String)
}

public struct HDTDictionary {
    public enum LookupPosition {
        case subject
        case predicate
        case object
    }
    
    var shared: [Int64: Term]
    var subjects: [Int64: Term]
    var predicates: [Int64: Term]
    var objects: [Int64: Term]
    
    public var count: Int {
        return shared.count + subjects.count + predicates.count + objects.count
    }
    
    public func term(for id: Int64, position: LookupPosition) -> Term? {
        if case .predicate = position {
            return predicates[id]
        } else {
            if let t = shared[id] {
                return t
            } else if let t = subjects[id] {
                return t
            } else {
                return objects[id]
            }
        }
    }
}

struct DictionaryMetadata {
    enum DictionaryType {
        case fourPart
    }
    
    var type: DictionaryType
    var offset: off_t
    var sharedOffset: off_t
    var subjectsOffset: off_t
    var predicatesOffset: off_t
    var objectsOffset: off_t
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
        let ordering = ["SPO", "SOP", "PSO", "POS", "OSP", "OPS"]
        return ordering[rawValue]
    }
}

struct TriplesMetadata {
    enum Format {
        case bitmap
        case list
    }
    
    var format: Format
    var ordering: TripleOrdering
    var offset: off_t
}

public class HDT: FileBased {
    var filename: String
    var header: String
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    public var state: FileState
    var soCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
    var pCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })

    init(filename: String, header: String, triples: TriplesMetadata, dictionary: DictionaryMetadata) throws {
        self.filename = filename
        self.header = header
        self.triplesMetadata = triples
        self.dictionaryMetadata = dictionary
        self.state = .none
        
        try openHDT(filename)
    }
    
    private func openHDT(_ filename: String) throws {
        let fd = open(filename, O_RDONLY)
        guard fd >= 0 else {
            var e = Int8(errno)
            perror(&e)
            throw HDTError.error("failed to open HDT file")
        }
        self.state = .opened(fd)
    }

    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        let tripleIDs = try readTriples(at: self.triplesMetadata.offset)
        
        let triples = tripleIDs.lazy.compactMap { t -> Triple? in
            guard let s = dictionary.term(for: t.0, position: .subject) else {
                return nil
            }
            guard let p = dictionary.term(for: t.1, position: .predicate) else {
                return nil
            }
            guard let o = dictionary.term(for: t.2, position: .object) else {
                return nil
            }
            return Triple(subject: s, predicate: p, object: o)
        }
        
        return AnyIterator(triples.makeIterator())
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
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 1 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
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

    struct BitmapTriplesData {
        var bitmapY : IndexSet
        var bitmapZ : IndexSet
        var arrayY : [Int64]
        var arrayZ : [Int64]
    }
    
    func readTriplesBitmap(at offset: off_t) throws -> (BitmapTriplesData, Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        warn("bitmap triples at \(offset)")
        let (bitmapY, byLength) = try readBitmap(at: offset)
        let (bitmapZ, bzLength) = try readBitmap(at: offset + byLength)
        let (arrayY, ayLength) = try readArray(at: offset + byLength + bzLength)
        let (arrayZ, azLength) = try readArray(at: offset + byLength + bzLength + ayLength)
        
        let length = byLength + bzLength + ayLength + azLength
        let data = BitmapTriplesData(bitmapY: bitmapY, bitmapZ: bitmapZ, arrayY: arrayY, arrayZ: arrayZ)
        return (data, length)
    }

    func readDictionaryTypeFour(at offset: off_t) throws -> HDTDictionary {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 64 * 1024 * 1024
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary") }
        
        var offset = offset
        
        warn("reading dictionary: shared at \(offset)")
        let (shared, sharedLength) = try readDictionaryPartition(at: offset, generator: soCounter)
        offset += sharedLength
        warn("read \(shared.count) shared terms")
        
        warn("offset: \(offset)")
        
        warn("reading dictionary: subjects at \(offset)")
        let (subjects, subjectsLength) = try readDictionaryPartition(at: offset, generator: soCounter)
        offset += subjectsLength
        warn("read \(subjects.count) subject terms")
        
        warn("reading dictionary: predicates at \(offset)")
        let (predicates, predicatesLength) = try readDictionaryPartition(at: offset, generator: pCounter)
        offset += predicatesLength
        warn("read \(predicates.count) predicate terms")
        
        warn("reading dictionary: objects at \(offset)")
        let (objects, objectsLength) = try readDictionaryPartition(at: offset, generator: soCounter)
        offset += objectsLength
        warn("read \(objects.count) object terms")
        
        let currentLength = sharedLength + subjectsLength + predicatesLength + objectsLength
        let currentPostion = offset + currentLength
        //        warn("current postion after dictionary read: \(currentPostion)")
        
        return HDTDictionary(shared: shared, subjects: subjects, predicates: predicates, objects: objects)
    }
    
    func readDictionary(at offset: off_t) throws -> HDTDictionary {
//        guard let mappingString = info.properties["mapping"] else {
//            throw HDTError.error("No mapping found in dictionary control information")
//        }
//        guard let mapping = Int(mappingString) else {
//            throw HDTError.error("Invalid mapping found in dictionary control information")
//        }
//        //        warn("Dictionary mapping: \(mapping)")
        switch dictionaryMetadata.type {
        case .fourPart:
            let d = try readDictionaryTypeFour(at: dictionaryMetadata.offset)
            return d
        default:
            throw HDTError.error("unimplemented dictionary format type: \(dictionaryMetadata.type)")
        }
    }

    func readDictionaryPartition(at offset: off_t, generator: AnyIterator<Int64>) throws -> ([Int64: Term], Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 64 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary") }
        
        // NOTE: HDT docs say this should be a u32, but the code says otherwise
        let d = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = UInt32(d.pointee)
        let typeLength : Int64 = 1
        warn("dictionary type: \(type) (at offset \(offset))")
        guard type == 2 else {
            throw HDTError.error("Dictionary partition: Trying to read a CSD_PFC but type does not match: \(type)")
        }
        
        var ptr = readBuffer + Int(typeLength)
        let _c = ptr.assumingMemoryBound(to: CChar.self)
        warn(String(format: "reading dictionary partition at offset \(offset); starting bytes: %02x %02x %02x %02x %02x", _c[0], _c[1], _c[2], _c[3], _c[4]))
        
        let stringCount = Int(readVByte(&ptr)) // numstrings
        let bytesCount = Int(readVByte(&ptr))
        let blockSize = Int(readVByte(&ptr))
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        warn("dictionary entries: \(stringCount)")
        warn("dictionary byte count: \(bytesCount)")
        warn("dictionary block size: \(blockSize)")
        warn("CRC: \(String(format: "%02x\n", Int(crc8)))")
        
        let (blocks, blocksLength) = try readSequence(at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
        warn("sequence length: \(blocksLength)")
        //        warn("sequence data (\(Array(blocks).count) elements): \(Array(blocks))")
        
        let blocksArray = Array(blocks)
        let dataBlockPosition = offset + dictionaryHeaderLength + blocksLength
        let (termDictionary, dataLength) = try readAllDictionaryBlocks(bufferBlocks: blocksArray, at: dataBlockPosition, length: bytesCount, count: stringCount, maximumStringsPerBlock: blockSize, generator: generator)
        ptr += Int(dataLength)
        
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        let crcLength = 4
        ptr += crcLength
        
        
        
        let length = dictionaryHeaderLength + blocksLength + dataLength + Int64(crcLength)
        return (termDictionary, length)
    }

    func readAllDictionaryBlocks<C: Collection>(bufferBlocks blocks: C, at offset: off_t, length size: Int, count: Int, maximumStringsPerBlock: Int, generator: AnyIterator<Int64>) throws -> ([Int64: Term], Int64) where C.Element == Int {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r >= size else { throw HDTError.error("Not enough bytes read for HDT dictionary buffer blocks") }
        var generated : Int64 = 0
        var dictionary = [Int64: Term]()
        let generateTerm = { (s: String) in
            let termID = generator.next()!
            generated += 1
            let id = termID
            if false {
                warn("    - TERM: \(id): \(s)")
            }
            
            if s.hasPrefix("_:") {
                dictionary[id] = Term(value: String(s.dropFirst(2)), type: .blank)
            } else if s.hasPrefix("\"") {
                dictionary[id] = Term(string: String(s.dropFirst().dropLast()))
                
                if s.contains("\"@") {
                    warn("TODO: handle language literals")
                } else if s.contains("\"^^") {
                    warn("TODO: handle datatype literals")
                }
            } else {
                dictionary[id] = Term(iri: s)
            }
        }
        
        var ptr = readBuffer
        for blockIndex in blocks.indices {
            let blockOffset = blocks[blockIndex]
            let ni = blocks.index(after: blockIndex)
            let next = ni == blocks.endIndex ? nil : blocks[ni]
            let startingID = generated
            
            let currentOffset = readBuffer.distance(to: ptr)
            if currentOffset >= size {
                //                warn("******** done 2")
                break
            }
            
            
            //            warn("buffer block at offset \(blockOffset)")
            ptr = readBuffer + blockOffset
            var commonPrefix = String(cString: ptr.assumingMemoryBound(to: CChar.self))
            //            warn("- first string in dictionary block: '\(commonPrefix)'")
            generateTerm(commonPrefix)
            ptr += commonPrefix.utf8.count + 1
            for _ in 1..<maximumStringsPerBlock {
                if generated >= count {
                    //                    warn("******** done 1")
                    break
                }
                
                let sharedPrefixLength = readVByte(&ptr)
                //                warn("-- shared prefix length: \(sharedPrefixLength)")
                let prefixData = commonPrefix.data(using: .utf8)!
                var bytes : [CChar] = prefixData.withUnsafeBytes { (ptr: UnsafePointer<CChar>) in
                    var bytes = [CChar]()
                    for i in 0..<Int(sharedPrefixLength) {
                        if ptr[i] == 0 {
                            break
                        }
                        bytes.append(ptr[i])
                    }
                    return bytes
                }
                
                let chars = ptr.assumingMemoryBound(to: CChar.self)
                var suffixLength = 0
                for i in 0... {
                    suffixLength += 1
                    if chars[i] == 0 {
                        break
                    }
                    bytes.append(chars[i])
                }
                bytes.append(0)
                ptr += suffixLength
                //                warn("-- suffix length: \(suffixLength)")
                
                commonPrefix = String(cString: bytes)
                generateTerm(commonPrefix)
                
                let generatedInBlock = generated - startingID
                if generatedInBlock >= maximumStringsPerBlock {
                    break
                }
                
                if let next = next {
                    let currentOffset = readBuffer.distance(to: ptr)
                    if currentOffset > next {
                        warn("blocks: \(blocks)")
                        warn("current offset: \(blockOffset)")
                        warn("generated \(generatedInBlock) terms in block")
                        warn("current offset in block \(currentOffset) extends beyond next block offset \(next)")
                        assert(false)
                    }
                    assert(readBuffer.distance(to: ptr) <= next)
                }
                assert(generated <= count)
            }
            
            let endingID = generated
            let generatedInBlock = endingID - startingID
            //            warn("generated \(generatedInBlock) terms in block")
        }
        
        let bytes = readBuffer.distance(to: ptr)
        return (dictionary, Int64(bytes))
    }
    
}

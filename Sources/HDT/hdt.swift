import Darwin
import Foundation
import BinUtils
import SPARQLSyntax
import CryptoSwift

public enum HDTError: Error {
    case error(String)
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

public struct HDT {
    var filename: String
    var ordering: TripleOrdering
    // TODO: hold dictionary ControlInformation, and buffer block offsets
    // TODO: hold triples ControlInformation and offset
}

public class HDTParser {
    enum ControlType : UInt8 {
        case unknown = 0
        case global = 1
        case header = 2
        case dictionary = 3
        case triples = 4
        case index = 5
    }
    
    struct ControlInformation {
        var type: ControlType
        var format: String
        var properties: [String:String]
        var crc: UInt16
        
        var tripleOrdering: TripleOrdering? {
            guard let orderNumber = properties["order"], let i = Int(orderNumber), let order = TripleOrdering(rawValue: i) else {
                return nil
            }
            return order
        }
    }
    
    enum DictionaryType : UInt32 {
        case dictionarySectionPlain = 1
        case dictionarySectionPlainFrontCoding = 2
    }
    enum State {
        case none
        case opened(CInt)
    }
    
    var state: State
    var idCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })

    public init() {
        self.state = .none
    }
    
    func openHDT(_ filename: String) throws {
        let fd = open(filename, O_RDONLY)
        guard fd >= 0 else {
            var e = Int8(errno)
            perror(&e)
            throw HDTError.error("failed to open HDT file")
        }
        self.state = .opened(fd)
    }
    
    func term(from dictionary: [Int64: Term], id: Int64) -> Term? {
        return dictionary[id]
    }
    
    public func triples(from filename: String) throws -> AnyIterator<Triple> {
        try openHDT(filename)
        var offset : Int64 = 0
        print("reading global control information at \(offset)")
        let (info, ciLength) = try readControlInformation(at: offset)
        offset += ciLength
        
        let (header, headerLength) = try readHeader(at: offset)
        offset += headerLength
        
        let (dictionary, dictionaryLength) = try readDictionary(at: offset)
        for (k, v) in dictionary.keys.sorted().map({ ($0, dictionary[$0]!) }) {
            print("TERM: \(k): \(v)")
        }
        offset += dictionaryLength
        
        let (tripleIDs, triplesLength) = try readTriples(at: offset)
        offset += triplesLength
        
        let triples = tripleIDs.lazy.compactMap { t -> Triple? in
            guard let s = self.term(from: dictionary, id: t.0) else {
                return nil
            }
            guard let p = self.term(from: dictionary, id: t.1) else {
                return nil
            }
            guard let o = self.term(from: dictionary, id: t.2) else {
                    return nil
            }
            return Triple(subject: s, predicate: p, object: o)
        }
        
        return AnyIterator(triples.makeIterator())
    }
    
    public func parse(_ filename: String) throws {
        try openHDT(filename)
        var offset : Int64 = 0
        print("reading global control information at \(offset)")
        let (info, ciLength) = try readControlInformation(at: offset)
        offset += ciLength

        let (header, headerLength) = try readHeader(at: offset)
        offset += headerLength
        
        let (termDictionary, dictionaryLength) = try readDictionary(at: offset)
        offset += dictionaryLength
        
        let (triples, triplesLength) = try readTriples(at: offset)
        offset += triplesLength
        
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
//            print("vbyte: \(String(format: "0x%02x", b)), byte value=\(bvalue), continue=\(cont)")
            p += 1
            value += bvalue << shift;
            shift += 7
        } while cont
        let bytes = ptr.distance(to: p)
//        print("read \(bytes) bytes to produce value \(value)")
        ptr = UnsafeMutableRawPointer(p)
        return value
    }

    func getField(_ index: Int, width bitsField: Int, from data: Data) -> Int {
        let type = UInt32.self
        let W = type.bitWidth
        let bitPos = index * bitsField
        let i = bitPos / W
        let j = bitPos % W
        if (j+bitsField) <= W {
            let d : UInt32 = data.withUnsafeBytes { $0[i] }
            return Int((d << (W-j-bitsField)) >> (W-bitsField))
        } else {
            let _r : UInt32 = data.withUnsafeBytes { $0[i] }
            let _d : UInt32 = data.withUnsafeBytes { $0[i+1] }
            let r = Int(_r >> j)
            let d = Int(_d << ((W<<1) - j - bitsField))
            return r | (d >> (W-bitsField))
        }
    }
    
    func readData(at offset: off_t, length: Int) throws -> Data {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
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
    
    func readSequence(at offset: off_t, assertType: UInt8? = nil) throws -> (AnySequence<Int>, Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
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
            print("Sequence type: \(type)")
        } else {
            typeLength = 0
        }

        let bits = Int(p[typeLength])
        let bitsLength = 1
        print("Sequence bits: \(bits)")

        var ptr = readBuffer + typeLength + bitsLength
        let entriesCount = Int(readVByte(&ptr))
        print("Sequence entries: \(entriesCount)")
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        // TODO: verify crc
        ptr += 1

        let arraySize = (bits * entriesCount + 7) / 8
        print("Array size for log sequence: \(arraySize)")
        let sequenceDataOffset = Int64(readBuffer.distance(to: ptr))
        print("Offset for log sequence: \(sequenceDataOffset)")
        
        let sequenceData = try readData(at: offset + sequenceDataOffset, length: arraySize)
        ptr += arraySize
        
        var values = [Int](reserveCapacity: entriesCount)
        for i in 0..<entriesCount {
            let value = getField(i, width: bits, from: sequenceData)
            values.append(value)
        }
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        ptr += 4
        
        let length = Int64(readBuffer.distance(to: ptr))

        let seq = AnySequence(values)
        return (seq, length)
    }
    
    func readAllDictionaryBlocks<C: Collection>(bufferBlocks blocks: C, at offset: off_t, length size: Int, count: Int, maximumStringsPerBlock: Int) throws -> ([Int64: Term], Int64) where C.Element == Int {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r >= size else { throw HDTError.error("Not enough bytes read for HDT dictionary buffer blocks") }
        var generated : Int64 = 0
        var dictionary = [Int64: Term]()
        let generateTerm = { (s: String) in
            let termID = self.idCounter.next()!
            generated += 1
            let id = termID
            if false {
                print("    - \(id): \(s)")
            }
            
            if s.hasPrefix("_:") {
                dictionary[id] = Term(value: String(s.dropFirst(2)), type: .blank)
            } else if s.hasPrefix("\"") {
                dictionary[id] = Term(string: String(s.dropFirst().dropLast()))
                    
                if s.contains("\"@") {
                    print("TODO: handle language literals")
                } else if s.contains("\"^^") {
                    print("TODO: handle datatype literals")
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
//                print("******** done 2")
                break
            }
            

//            print("buffer block at offset \(blockOffset)")
            ptr = readBuffer + blockOffset
            var commonPrefix = String(cString: ptr.assumingMemoryBound(to: CChar.self))
//            print("- first string in dictionary block: '\(commonPrefix)'")
            generateTerm(commonPrefix)
            ptr += commonPrefix.utf8.count + 1
            for _ in 1..<maximumStringsPerBlock {
                if generated >= count {
//                    print("******** done 1")
                    break
                }
                
                let sharedPrefixLength = readVByte(&ptr)
//                print("-- shared prefix length: \(sharedPrefixLength)")
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
//                print("-- suffix length: \(suffixLength)")

                commonPrefix = String(cString: bytes)
                generateTerm(commonPrefix)
                
                let generatedInBlock = generated - startingID
                if generatedInBlock >= maximumStringsPerBlock {
                    break
                }
                
                if let next = next {
                    let currentOffset = readBuffer.distance(to: ptr)
                    if currentOffset > next {
                        print("blocks: \(blocks)")
                        print("current offset: \(blockOffset)")
                        print("generated \(generatedInBlock) terms in block")
                        print("current offset in block \(currentOffset) extends beyond next block offset \(next)")
                        assert(false)
                    }
                    assert(readBuffer.distance(to: ptr) <= next)
                }
                assert(generated <= count)
            }

            let endingID = generated
            let generatedInBlock = endingID - startingID
//            print("generated \(generatedInBlock) terms in block")
        }
        
        let bytes = readBuffer.distance(to: ptr)
        return (dictionary, Int64(bytes))
    }
    
    func readDictionaryPartition(at offset: off_t) throws -> ([Int64: Term], Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 64 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary") }
        
        // NOTE: HDT docs say this should be a u32, but the code says otherwise
        let d = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = UInt32(d.pointee)
        let typeLength : Int64 = 1
        print("dictionary type: \(type) (at offset \(offset))")
        guard type == 2 else {
            throw HDTError.error("Dictionary partition: Trying to read a CSD_PFC but type does not match: \(type)")
        }

        var ptr = readBuffer + Int(typeLength)
        let _c = ptr.assumingMemoryBound(to: CChar.self)
        print(String(format: "reading dictionary partition at offset \(offset); starting bytes: %02x %02x %02x %02x %02x", _c[0], _c[1], _c[2], _c[3], _c[4]))
        
        
        
        
        let stringCount = Int(readVByte(&ptr)) // numstrings
        let bytesCount = Int(readVByte(&ptr))
        let blockSize = Int(readVByte(&ptr))
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        print("dictionary entries: \(stringCount)")
        print("dictionary byte count: \(bytesCount)")
        print("dictionary block size: \(blockSize)")
        print("CRC: \(String(format: "%02x\n", Int(crc8)))")
        
        let (blocks, blocksLength) = try readSequence(at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
        print("sequence length: \(blocksLength)")
        //        print("sequence data (\(Array(blocks).count) elements): \(Array(blocks))")
        
        let blocksArray = Array(blocks)
        let dataBlockPosition = offset + dictionaryHeaderLength + blocksLength
        let (termDictionary, dataLength) = try readAllDictionaryBlocks(bufferBlocks: blocksArray, at: dataBlockPosition, length: bytesCount, count: stringCount, maximumStringsPerBlock: blockSize)
        ptr += Int(dataLength)


        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        let crcLength = 4
        ptr += crcLength

        
        
        let length = dictionaryHeaderLength + blocksLength + dataLength + Int64(crcLength)
        return (termDictionary, length)
    }
    
    func readDictionaryTypeFour(at offset: off_t) throws -> ([Int64: Term], Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 64 * 1024 * 1024
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary") }

        var offset = offset
        
        print("reading dictionary: shared at \(offset)")
        let (shared, sharedLength) = try readDictionaryPartition(at: offset)
        offset += sharedLength
        print("read \(shared.count) shared terms")
        
        print("offset: \(offset)")
        assert(offset == 405268)
        
        print("reading dictionary: subjects at \(offset)")
        let (subjects, subjectsLength) = try readDictionaryPartition(at: offset)
        offset += subjectsLength
        print("read \(subjects.count) subject terms")

        print("reading dictionary: predicates at \(offset)")
        let (predicates, predicatesLength) = try readDictionaryPartition(at: offset)
        offset += predicatesLength
        print("read \(predicates.count) predicate terms")

        print("reading dictionary: objects at \(offset)")
        let (objects, objectsLength) = try readDictionaryPartition(at: offset)
        offset += objectsLength
        print("read \(objects.count) object terms")

        let currentLength = sharedLength + subjectsLength + predicatesLength + objectsLength
        let currentPostion = offset + currentLength
//        print("current postion after dictionary read: \(currentPostion)")
        
        var d = [Int64: Term]()
        d.merge(shared) {
            $1
        }
        d.merge(subjects) {
            $1
        }
        d.merge(predicates) {
            $1
        }
        d.merge(objects) {
            $1
        }

        return (d, currentLength)
    }
    
    func readDictionary(at offset: off_t) throws -> ([Int64: Term], Int64) {
        let (info, ciLength) = try readControlInformation(at: offset)
        print("dictionary control information: \(info)")
        print("-> next block at \(offset + ciLength)")
        guard let mappingString = info.properties["mapping"] else {
            throw HDTError.error("No mapping found in dictionary control information")
        }
        guard let mapping = Int(mappingString) else {
            throw HDTError.error("Invalid mapping found in dictionary control information")
        }
//        print("Dictionary mapping: \(mapping)")

        if info.format == "<http://purl.org/HDT/hdt#dictionaryFour>" {
            let (d, dLength) = try readDictionaryTypeFour(at: offset + ciLength)
            return (d, ciLength + dLength)
        } else {
            throw HDTError.error("unimplemented dictionary format type: \(info.format)")
        }
    }
    
    func readHeader(at offset: off_t) throws -> (String, Int64) {
        let (info, ciLength) = try readControlInformation(at: offset)
//        print("header control information: \(info)")

        guard info.format == "ntriples" else {
            throw HDTError.error("Header metadata format must be ntriples, but found '\(info.format)'")
        }

        guard let headerLengthString = info.properties["length"] else {
            throw HDTError.error("No length property found for header data")
        }

        guard let headerLength = Int(headerLengthString) else {
            throw HDTError.error("Invalid header length found in header metadata")
        }

        print("N-Triples header is \(headerLength) bytes")
        
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = headerLength
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset + ciLength)
        guard r > 2 else { throw HDTError.error("Not enough bytes read for HDT header") }
        let d = Data(bytes: readBuffer, count: r)
        guard let ntriples = String(data: d, encoding: .utf8) else {
            throw HDTError.error("Failed to decode header metadata as utf8")
        }

        let length = ciLength + Int64(headerLength)
        return (ntriples, length)
    }

    func readArray(at offset: off_t) throws -> ([Int64], Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
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
            print("array prefix: \(array.prefix(32))")
            return (array, blocksLength)
        case 2:
            fatalError("TODO: Array read unimplemented: uint32")
        case 3:
            fatalError("TODO: Array read unimplemented: uint64")
        default:
            throw HDTError.error("Invalid array type (\(type)) at offset \(offset)")
        }
    }
    
    func readBitmap(at offset: off_t) throws -> (IndexSet, Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
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
    
    struct BitmapTriplesData {
        var bitmapY : IndexSet
        var bitmapZ : IndexSet
        var arrayY : [Int64]
        var arrayZ : [Int64]
    }
    
    func generatePairs<I: IteratorProtocol, E>(elements: I, index bits: IndexSet, array: [E]) -> AnyIterator<(I.Element, E)> {
        var data = [(I.Element, E)]()
        var currentIndex = 0
        var elements = elements
        var array = array
        let gen = { () -> (I.Element, E)? in
            repeat {
                if !data.isEmpty {
//                    print("- removing element from pending array of size \(data.count)")
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
                
//                print("k=\(k)")
//                print("index set: \(bits)")
                
                let pairs = array.prefix(k).map { (next, $0) }
                array.removeFirst(k)
//                print("+ adding pending results x \(pairs.count)")
                data.append(contentsOf: pairs)
            } while true
        }
        return AnyIterator(gen)
    }
    
    func generateTriples<S: Sequence>(data: BitmapTriplesData, controlInformation info: ControlInformation, topLevelIDs gen: S) throws -> AnyIterator<(Int64, Int64, Int64)> where S.Element == Int64 {
        guard let order = info.tripleOrdering else {
            throw HDTError.error("Cannot parse bitmap triples block without valid triple ordering metadata")
        }
        
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
        fatalError("parse triples bitmap structures")
        throw HDTError.error("Bitmap triples parsing not implemented")
    }
    
    func readTriplesBitmap(at offset: off_t) throws -> (BitmapTriplesData, Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        print("bitmap triples at \(offset)")
        let (bitmapY, byLength) = try readBitmap(at: offset)
        let (bitmapZ, bzLength) = try readBitmap(at: offset + byLength)
        let (arrayY, ayLength) = try readArray(at: offset + byLength + bzLength)
        let (arrayZ, azLength) = try readArray(at: offset + byLength + bzLength + ayLength)
        
        let length = byLength + bzLength + ayLength + azLength
        let data = BitmapTriplesData(bitmapY: bitmapY, bitmapZ: bitmapZ, arrayY: arrayY, arrayZ: arrayZ)
        return (data, length)
    }
    
    func readTriplesList(at offset: off_t, controlInformation: ControlInformation) throws -> (AnyIterator<(Int64, Int64, Int64)>, Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        print("list triples at \(offset)")
        throw HDTError.error("List triples parsing not implemented")
    }
    
    func readTriples(at offset: off_t) throws -> (AnyIterator<(Int64, Int64, Int64)>, Int64) {
        print("reading triples at offset \(offset)")
        let (info, ciLength) = try readControlInformation(at: offset)
        print("triples control information: \(info)")

        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 1 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        guard let order = info.tripleOrdering else {
            throw HDTError.error("Missing or invalid ordering metadata present in triples block")
        }
        print("Triple block has ordering \(order)")
        
        switch info.format {
        case "<http://purl.org/HDT/hdt#triplesBitmap>":
            let (data, length) = try readTriplesBitmap(at: offset + ciLength)
            let gen = sequence(first: Int64(1)) { $0 + 1 } // TODO: this isn't right; this data needs to come from the dictionary
            let triples = try generateTriples(data: data, controlInformation: info, topLevelIDs: gen)
            return (triples, length)
        case "<http://purl.org/HDT/hdt#triplesList>":
            return try readTriplesList(at: offset + ciLength, controlInformation: info)
        default:
            throw HDTError.error("Unrecognized triples format: \(info.format)")
        }
    }
    
    func readControlInformation(at offset: off_t) throws -> (ControlInformation, Int64) {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 40960
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 6 else { throw HDTError.error("Not enough bytes read for HDT control information") }

        try findCookie(at: offset)
        let cookieLength = 4
        
        let cLength = 1
        let cPtr = readBuffer + cookieLength
        let cValue = cPtr.assumingMemoryBound(to: UInt8.self)[0]
        guard let c = ControlType(rawValue: cValue) else {
            throw HDTError.error("Unexpected value for Control Type: \(cValue) at offset \(offset)")
        }
//        print("Found control byte: \(c)")

        let fValue = (readBuffer + cookieLength + cLength).assumingMemoryBound(to: CChar.self)
        let format = String(cString: fValue)
//        print("Found format: \(format)")
        
        let fLength = format.utf8.count + 1
        
        let pValue = (readBuffer + cookieLength + cLength + fLength).assumingMemoryBound(to: CChar.self)
        let propertiesString = String(cString: pValue)
        var properties = [String:String]()
        if !propertiesString.isEmpty {
            let pairs = propertiesString.split(separator: ";").map { (kv) -> (String, String) in
                let a = String(kv).split(separator: "=")
                return (String(a[0]), String(a[1]))
            }
            properties = Dictionary(uniqueKeysWithValues: pairs)
//            print("Found properties: \(properties)")
        }
        
        let pLength = propertiesString.utf8.count + 1
        
        let crcPtr = (readBuffer + cookieLength + cLength + fLength + pLength)
        let crc16 = UInt16(bigEndian: crcPtr.assumingMemoryBound(to: UInt16.self).pointee)
        let crcLength = 2
        let crcContent = Data(bytes: readBuffer, count: cookieLength + cLength + fLength + pLength)
        let expected = crcContent.crc16().withUnsafeBytes { (p : UnsafePointer<UInt16>) in p.pointee }
        guard crc16 == expected else {
            throw HDTError.error(String(format: "Bad Control Information checksum: %04x, expecting %04x", Int(crc16), Int(expected)))
        }

        let length = cookieLength + cLength + fLength + pLength + crcLength
        let ci = ControlInformation(type: c, format: format, properties: properties, crc: crc16)
        return (ci, Int64(length))
    }
    
    func findCookie(at offset: off_t) throws {
        guard case .opened(let fd) = state else { throw HDTError.error("HDT file not opened") }
        let size = 4
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r == size else { throw HDTError.error("Expecting \(size) bytes, but only read \(r)") }
        let d = Data(bytes: readBuffer, count: r)
        let expected = "$HDT".data(using: .utf8)
        let cookie = UInt32(bigEndian: readBuffer.assumingMemoryBound(to: UInt32.self).pointee)
        guard d == expected else {
            throw HDTError.error("Bad HDT cookie at offset \(offset): \(String(format: "0x%08x", cookie))")
        }
//        print("Found HDT cookie at offset \(offset)")
    }
}

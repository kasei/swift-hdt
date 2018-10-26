import Darwin
import Foundation
import SPARQLSyntax
import CryptoSwift
import os.log
import os.signpost

public class HDTMMapParser {
    let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
    
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
    
    var filename: String
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    
    public init(filename: String) throws {
        self.filename = filename
        let fd = open(filename, O_RDONLY)
        if fd <= 0 {
            throw HDTError.error("Error opening file \(filename)")
        }
        
        var statbuf: stat = stat()
        let r = stat(filename, &statbuf)
        if r != 0 {
            throw HDTError.error("Error getting file stat info")
        }
        
        size = Int(statbuf.st_size)
        mmappedPtr = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0)
        if mmappedPtr == MAP_FAILED {
            throw HDTError.error("Error memory mapping file \(filename)")
        }
        
        // Mark as needed so the OS keeps as much as possible in memory
        madvise(mmappedPtr, size, MADV_WILLNEED)
    }
    
    public func triples(from filename: String) throws -> AnyIterator<Triple> {
        let hdt = try parse()
        return try hdt.triples()
    }
    
    public func parse() throws -> MemoryMappedHDT {
        var offset : Int64 = 0
        warn("reading global control information at \(offset)")
        let (info, ciLength) = try readControlInformation(at: offset)
        offset += ciLength
        
        os_signpost(.begin, log: log, name: "Parsing Header", "Begin")
        let (header, headerLength) = try readHeader(at: offset)
        offset += headerLength
        os_signpost(.end, log: log, name: "Parsing Header", "Finished")
        
        os_signpost(.begin, log: log, name: "Parsing Dictionary", "Finished")
        let (dictionary, dictionaryLength) = try parseDictionary(at: offset)
        offset += dictionaryLength
        os_signpost(.end, log: log, name: "Parsing Dictionary", "Finished")
        
        os_signpost(.begin, log: log, name: "Parsing Triples", "Finished")
        let triples = try parseTriples(at: offset)
        os_signpost(.end, log: log, name: "Parsing Triples", "Finished")
        
        return try MemoryMappedHDT(
            filename: filename,
            size: size,
            ptr: mmappedPtr,
            header: header,
            triples: triples,
            dictionary: dictionary
        )
    }
    
    func parseDictionaryPartition(at offset: off_t) throws -> Int64 {
        var readBuffer = mmappedPtr
        readBuffer += Int(offset)

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
        //        warn("dictionary entries: \(stringCount)")
        //        warn("dictionary byte count: \(bytesCount)")
        //        warn("dictionary block size: \(blockSize)")
        //        warn("CRC: \(String(format: "%02x\n", Int(crc8)))")
        
        let (blocks, blocksLength) = try readSequence(from: mmappedPtr, at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
        //        warn("sequence length: \(blocksLength)")
        
        //        let blocksArray = Array(blocks)
        //        let dataBlockPosition = offset + dictionaryHeaderLength + blocksLength
        let dataLength = Int64(bytesCount)
        
        //        warn(dataLength)
        //        warn(bytesCount)
        //        warn("====")
        
        ptr += Int(dataLength)
        
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        let crcLength = 4
        ptr += crcLength
        
        let length = dictionaryHeaderLength + blocksLength + dataLength + Int64(crcLength)
        return length
    }
    
    func parseDictionaryTypeFour(at offset: off_t) throws -> (DictionaryMetadata, Int64) {
        var readBuffer = mmappedPtr
        var offset = offset
        let dictionaryOffset = offset
        
        warn("reading dictionary: shared at \(offset)")
        let sharedOffset = offset
        let sharedLength = try parseDictionaryPartition(at: offset)
        offset += sharedLength
        
        warn("reading dictionary: subjects at \(offset)")
        let subjectsOffset = offset
        let subjectsLength = try parseDictionaryPartition(at: offset)
        offset += subjectsLength
        
        warn("reading dictionary: predicates at \(offset)")
        let predicatesOffset = offset
        let predicatesLength = try parseDictionaryPartition(at: offset)
        offset += predicatesLength
        
        warn("reading dictionary: objects at \(offset)")
        let objectsOffset = offset
        let objectsLength = try parseDictionaryPartition(at: offset)
        offset += objectsLength
        
        let currentLength = sharedLength + subjectsLength + predicatesLength + objectsLength
        let currentPostion = offset + currentLength
        
        let offsets = DictionaryMetadata(
            type: .fourPart,
            offset: dictionaryOffset,
            sharedOffset: sharedOffset,
            subjectsOffset: subjectsOffset,
            predicatesOffset: predicatesOffset,
            objectsOffset: objectsOffset
        )
        return (offsets, currentLength)
    }
    
    func parseDictionary(at offset: off_t) throws -> (DictionaryMetadata, Int64) {
        let (info, ciLength) = try readControlInformation(at: offset)
        warn("dictionary control information: \(info)")
        warn("-> next block at \(offset + ciLength)")
        guard let mappingString = info.properties["mapping"] else {
            throw HDTError.error("No mapping found in dictionary control information")
        }
        guard let mapping = Int(mappingString) else {
            throw HDTError.error("Invalid mapping found in dictionary control information")
        }
        //        warn("Dictionary mapping: \(mapping)")
        
        if info.format == "<http://purl.org/HDT/hdt#dictionaryFour>" {
            let (offsets, dLength) = try parseDictionaryTypeFour(at: offset + ciLength)
            return (offsets, ciLength + dLength)
        } else {
            throw HDTError.error("unimplemented dictionary format type: \(info.format)")
        }
    }
    
    func readHeader(at offset: off_t) throws -> (String, Int64) {
        let (info, ciLength) = try readControlInformation(at: offset)
        //        warn("header control information: \(info)")
        
        guard info.format == "ntriples" else {
            throw HDTError.error("Header metadata format must be ntriples, but found '\(info.format)'")
        }
        
        guard let headerLengthString = info.properties["length"] else {
            throw HDTError.error("No length property found for header data")
        }
        
        guard let headerLength = Int(headerLengthString) else {
            throw HDTError.error("Invalid header length found in header metadata")
        }
        
        warn("N-Triples header is \(headerLength) bytes")
        
        let size = headerLength
        let readBuffer = mmappedPtr + Int(offset) + Int(ciLength)
        let d = Data(bytes: readBuffer, count: size)
        guard let ntriples = String(data: d, encoding: .utf8) else {
            throw HDTError.error("Failed to decode header metadata as utf8")
        }
        
        let length = ciLength + Int64(headerLength)
        return (ntriples, length)
    }
    
    
    struct BitmapTriplesData {
        var bitmapY : IndexSet
        var bitmapZ : IndexSet
        var arrayY : [Int64]
        var arrayZ : [Int64]
    }
    
    func readTriplesBitmap(at offset: off_t) throws -> (BitmapTriplesData, Int64) {
        var readBuffer = mmappedPtr
        
        warn("bitmap triples at \(offset)")
        let (bitmapY, byLength) = try readBitmap(from: mmappedPtr, at: offset)
        let (bitmapZ, bzLength) = try readBitmap(from: mmappedPtr, at: offset + byLength)
        let (arrayY, ayLength) = try readArray(from: mmappedPtr, at: offset + byLength + bzLength)
        let (arrayZ, azLength) = try readArray(from: mmappedPtr, at: offset + byLength + bzLength + ayLength)
        
        let length = byLength + bzLength + ayLength + azLength
        let data = BitmapTriplesData(bitmapY: bitmapY, bitmapZ: bitmapZ, arrayY: arrayY, arrayZ: arrayZ)
        return (data, length)
    }
    
    func readTriplesList(at offset: off_t, controlInformation: ControlInformation) throws -> (AnyIterator<(Int64, Int64, Int64)>, Int64) {
        var readBuffer = mmappedPtr
        
        warn("list triples at \(offset)")
        throw HDTError.error("List triples parsing not implemented")
    }
    
    func parseTriples(at offset: off_t) throws -> TriplesMetadata {
        warn("reading triples at offset \(offset)")
        let (info, ciLength) = try readControlInformation(at: offset)
        warn("triples control information: \(info)")
        
        var readBuffer = mmappedPtr
        
        guard let order = info.tripleOrdering else {
            throw HDTError.error("Missing or invalid ordering metadata present in triples block")
        }
        warn("Triple block has ordering \(order)")
        
        switch info.format {
        case "<http://purl.org/HDT/hdt#triplesBitmap>":
            return TriplesMetadata(format: .bitmap, ordering: order, offset: offset + ciLength)
        case "<http://purl.org/HDT/hdt#triplesList>":
            return TriplesMetadata(format: .list, ordering: order, offset: offset + ciLength)
        default:
            throw HDTError.error("Unrecognized triples format: \(info.format)")
        }
    }
    
    func readControlInformation(at offset: off_t) throws -> (ControlInformation, Int64) {
        var readBuffer = mmappedPtr
        readBuffer += Int(offset)

        try findCookie(at: offset)
        let cookieLength = 4
        
        let cLength = 1
        let cPtr = readBuffer + cookieLength
        let cValue = cPtr.assumingMemoryBound(to: UInt8.self)[0]
        guard let c = ControlType(rawValue: cValue) else {
            throw HDTError.error("Unexpected value for Control Type: \(cValue) at offset \(offset)")
        }
        //        warn("Found control byte: \(c)")
        
        let fValue = (readBuffer + cookieLength + cLength).assumingMemoryBound(to: CChar.self)
        let format = String(cString: fValue)
        //        warn("Found format: \(format)")
        
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
            //            warn("Found properties: \(properties)")
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
        let size = 4
        var readBuffer = mmappedPtr
        readBuffer += Int(offset)

        let d = Data(bytes: readBuffer, count: 4)
        let expected = "$HDT".data(using: .utf8)
        let cookie = UInt32(bigEndian: readBuffer.assumingMemoryBound(to: UInt32.self).pointee)
        guard d == expected else {
            throw HDTError.error("Bad HDT cookie at offset \(offset): \(String(format: "0x%08x", cookie))")
        }
        //        warn("Found HDT cookie at offset \(offset)")
    }
}

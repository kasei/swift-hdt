import Darwin
import Foundation
import SPARQLSyntax
import CryptoSwift
import os.log
import os.signpost

public class HDTParser {
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
    
    public func parse() throws -> HDT {
        var offset : Int64 = 0
        let (_, ciLength) = try readControlInformation(at: offset)
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
        
        return try HDT(
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
        guard type == 2 else {
            throw HDTError.error("Dictionary partition: Trying to read a CSD_PFC but type does not match: \(type)")
        }
        
        var ptr = readBuffer + Int(typeLength)
        _ = Int(readVByte(&ptr)) // string count
        let bytesCount = Int(readVByte(&ptr))
        _ = Int(readVByte(&ptr)) // block size
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        
        let (_, blocksLength) = try readSequence(from: mmappedPtr, at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)

        let dataLength = Int64(bytesCount)
        ptr += Int(dataLength)
        
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        let crcLength = 4
        ptr += crcLength
        
        let length = dictionaryHeaderLength + blocksLength + dataLength + Int64(crcLength)
        return length
    }
    
    func parseDictionaryTypeFour(at offset: off_t) throws -> (DictionaryMetadata, Int64) {
        var offset = offset
        let dictionaryOffset = offset
        
        let sharedOffset = offset
        let sharedLength = try parseDictionaryPartition(at: offset)
        offset += sharedLength
        
        let subjectsOffset = offset
        let subjectsLength = try parseDictionaryPartition(at: offset)
        offset += subjectsLength
        
        let predicatesOffset = offset
        let predicatesLength = try parseDictionaryPartition(at: offset)
        offset += predicatesLength
        
        let objectsOffset = offset
        let objectsLength = try parseDictionaryPartition(at: offset)
        offset += objectsLength
        
        let currentLength = sharedLength + subjectsLength + predicatesLength + objectsLength
        
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
        
        if info.format == "<http://purl.org/HDT/hdt#dictionaryFour>" {
            let (offsets, dLength) = try parseDictionaryTypeFour(at: offset + ciLength)
            return (offsets, ciLength + dLength)
        } else {
            throw HDTError.error("unimplemented dictionary format type: \(info.format)")
        }
    }
    
    func readHeader(at offset: off_t) throws -> (String, Int64) {
        let (info, ciLength) = try readControlInformation(at: offset)
        
        guard info.format == "ntriples" else {
            throw HDTError.error("Header metadata format must be ntriples, but found '\(info.format)'")
        }
        
        guard let headerLengthString = info.properties["length"] else {
            throw HDTError.error("No length property found for header data")
        }
        
        guard let headerLength = Int(headerLengthString) else {
            throw HDTError.error("Invalid header length found in header metadata")
        }
        
        let size = headerLength
        let readBuffer = mmappedPtr + Int(offset) + Int(ciLength)
        let d = Data(bytes: readBuffer, count: size)
        guard let ntriples = String(data: d, encoding: .utf8) else {
            throw HDTError.error("Failed to decode header metadata as utf8")
        }
        
        let length = ciLength + Int64(headerLength)
        return (ntriples, length)
    }
    
    
    func parseTriples(at offset: off_t) throws -> TriplesMetadata {
        let (info, ciLength) = try readControlInformation(at: offset)
        
        guard let order = info.tripleOrdering else {
            throw HDTError.error("Missing or invalid ordering metadata present in triples block")
        }
        
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
        
        let fValue = (readBuffer + cookieLength + cLength).assumingMemoryBound(to: CChar.self)
        let format = String(cString: fValue)
        
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

        let d = Data(bytes: readBuffer, count: size)
        let expected = "$HDT".data(using: .utf8)
        let cookie = UInt32(bigEndian: readBuffer.assumingMemoryBound(to: UInt32.self).pointee)
        guard d == expected else {
            throw HDTError.error("Bad HDT cookie at offset \(offset): \(String(format: "0x%08x", cookie))")
        }
    }
}

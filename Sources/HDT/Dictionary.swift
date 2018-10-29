import Foundation
import SPARQLSyntax
import os.log
import os.signpost

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

public enum LookupPosition {
    case subject
    case predicate
    case object
}

public protocol HDTDictionaryProtocol {
    var count: Int { get }
    func term(for id: Int64, position: LookupPosition) throws -> Term?
    func id(for term: Term, position: LookupPosition) throws -> Int64?
    func idSequence(for position: LookupPosition) -> AnySequence<Int64>
}

public final class HDTLazyFourPartDictionary : HDTDictionaryProtocol {
    let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
    
    struct DictionarySectionMetadata {
        var count: Int
        var offset: Int64
        var dataOffset: Int64
        var length: Int64
        var blockSize: Int
        var startingID: Int
        var sharedBlocks: [Int]
    }

    var rdfParser: SerdParser
    var cache: [LookupPosition: [Int64: Term]]
    var metadata: DictionaryMetadata
    var shared: DictionarySectionMetadata!
    var subjects: DictionarySectionMetadata!
    var predicates: DictionarySectionMetadata!
    var objects: DictionarySectionMetadata!
    public var cacheMaxSize = 4 * 1024
    var cacheReachedFullState = false
    
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    
    init(metadata: DictionaryMetadata, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer) throws {
        self.cache = [.subject: [:], .predicate: [:], .object: [:]]
        self.mmappedPtr = mmappedPtr
        self.size = size
        self.metadata = metadata
        self.rdfParser = SerdParser(syntax: .turtle, base: "http://example.org/", produceUniqueBlankIdentifiers: false)

        var offset = metadata.offset
        
//        warn("reading dictionary: shared at \(offset)")
        self.shared = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += self.shared.length
//        warn("read \(shared.count) shared terms")
        
//        warn("offset: \(offset)")
        
//        warn("reading dictionary: subjects at \(offset)")
        self.subjects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += self.subjects.length
//        warn("read \(subjects.count) subject terms")
        
//        warn("reading dictionary: predicates at \(offset)")
        self.predicates = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += self.predicates.length
//        warn("read \(predicates.count) predicate terms")
        
//        warn("reading dictionary: objects at \(offset)")
        self.objects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += self.objects.length
//        warn("read \(objects.count) object terms")
    }
    
    public func forEach(_ body: (LookupPosition, Int64, Term) throws -> Void) rethrows {
        let sections : [DictionarySectionMetadata] = [predicates, objects]
        let positions : [LookupPosition] = [.predicate, .object]
        for (section, position) in zip(sections, positions) {
            try (0..<section.count).forEach { (count) in
                let id = count + section.startingID
                if let term = try term(for: Int64(id), position: position) {
                    try body(position, Int64(id), term)
                } else {
                    fatalError("Unexpectedly failed to look up term for id \(id) in section \(section)")
                }
            }
        }
    }
    
    public var count: Int {
        return shared.count + subjects.count + predicates.count + objects.count
    }
    
    public func term(for id: Int64, position: LookupPosition) throws -> Term? {
        switch position {
        case .subject:
            if id <= shared.count {
                return try term(for: id, from: shared, position: position)
            } else {
                return try term(for: id, from: subjects, position: position)
            }
        case .predicate:
            return try term(for: id, from: predicates, position: position)
        case .object:
            if id <= shared.count {
                return try term(for: id, from: shared, position: position)
            } else {
                return try term(for: id, from: objects, position: position)
            }
        }
    }
    
    public func id(for lookupTerm: Term, position: LookupPosition) throws -> Int64? {
        switch position {
        case .subject:
            for id in idSequence(for: .subject) {
                let t = try term(for: Int64(id), position: position)
                if t == lookupTerm {
                    return Int64(id)
                }
            }
        case .predicate:
            for id in idSequence(for: .predicate) {
                let t = try term(for: Int64(id), position: position)
                if t == lookupTerm {
                    return Int64(id)
                }
            }
        case .object:
            for id in idSequence(for: .object) {
                let t = try term(for: Int64(id), position: position)
                if t == lookupTerm {
                    return Int64(id)
                }
            }
        }
        return nil
    }

    public func idSequence(for position: LookupPosition) -> AnySequence<Int64> {
        return AnySequence { () -> AnyIterator<Int64> in
            switch position {
            case .subject:
                let range = Int64(1)..<Int64(self.shared.count + self.subjects.count)
                return AnyIterator(range.makeIterator())
            case .predicate:
                let range = Int64(1)..<Int64(self.predicates.count)
                return AnyIterator(range.makeIterator())
            case .object:
                let range1 = Int64(1)..<Int64(self.shared.count)
                let min = self.shared.count + self.subjects.count + 1
                let range2 = Int64(min)..<Int64(min + self.objects.count)
                let i = ConcatenateIterator(range1.makeIterator(), range2.makeIterator())
                return AnyIterator(i)
            }
        }
    }

    private func updateCache(for id: Int64, position: LookupPosition, dictionary: [Int64:Term]) {
        let count = cache[position]!.count
        if count == cacheMaxSize {
            if !cacheReachedFullState {
                os_signpost(.event, log: log, name: "Dictionary", "%{public}s cache reached cache maximum size of %{public}d", "\(position)", count)
            }
        } else if count > cacheMaxSize {
            cacheReachedFullState = true
            for _ in 0..<32 {
                if let k = cache[position]!.keys.randomElement() {
                    cache[position]!.removeValue(forKey: k)
                }
            }
        }
        
        cache[position]?.merge(dictionary, uniquingKeysWith: { (a, b) in a })
//        warn("\(position) cache has \(cache[position]?.count ?? 0) items")
    }
    
    private func cachedTerm(for id: Int64, from section: DictionarySectionMetadata, position: LookupPosition) -> Term? {
        let positionCache = cache[position]!
        return positionCache[id]
    }
    
    private func term(for id: Int64, from section: DictionarySectionMetadata, position: LookupPosition) throws -> Term? {
        // this is a heuristic for SPO-ordered HDT files; S and P will benefit from caching,
        // but there will be lots of churn in O due to the ordering, so we don't attempt to
        // cache O values at all.
        if position != .object, let term = cachedTerm(for: id, from: section, position: position) {
            return term
        } else {
            do {
                let dictionary = try probeDictionary(from: mmappedPtr, section: section, for: id)
                if position != .object {
                    updateCache(for: id, position: position, dictionary: dictionary)
                }
                let term = dictionary[id]
                return term
            } catch let error {
                print("\(error)")
                return nil
            }
        }
    }

    private func term(from s: String) throws -> Term {
        if s.hasPrefix("_") { // blank nodes start _:
            return Term(value: String(s.dropFirst(2)), type: .blank)
        } else if s.hasPrefix("\"") {
            var term: Term? = nil
            _ = try rdfParser.parse(string: "<s> <p> \(s) .") { (s, p, o) in
                term = o
            }
            guard let t = term else {
                throw HDTError.error("Failed to parse literal value")
            }
            return t
        } else {
            return Term(iri: s)
        }
    }
    
    private func probeDictionary(from mmappedPtr: UnsafeMutableRawPointer, section: DictionarySectionMetadata, for id: Int64) throws -> [Int64: Term] {
        var nextID = Int64(section.startingID)
        let offset = section.dataOffset
        let maximumStringsPerBlock = section.blockSize
        
        let readBuffer = mmappedPtr + Int(offset)

        var dictionary = [Int64: Term]()
        
        let blocks = section.sharedBlocks
        
        let localIDOffset = id - Int64(section.startingID)
        let skipBlocks = Int(localIDOffset/Int64(maximumStringsPerBlock))
        nextID += Int64(skipBlocks * maximumStringsPerBlock)
        
        let blockMaxID = (section.startingID + section.count - 1)
        let blockIndex = blocks.dropFirst(skipBlocks).startIndex
        let blockOffset = blocks[blockIndex]
        var ptr = readBuffer + blockOffset
        let charsPtr = ptr.assumingMemoryBound(to: CChar.self)
        
        var commonPrefix = String(cString: charsPtr)
        let charsBufferPtr = UnsafeBufferPointer(start: charsPtr, count: commonPrefix.utf8.count)
        var commonPrefixChars = Array(charsBufferPtr)
        
        let t = try self.term(from: commonPrefix)
        let newID = nextID
        nextID += 1
        //            warn("    - TERM: \(newID): \(t)")
        dictionary[newID] = t
        if newID == id {
            return dictionary
        } else if newID >= blockMaxID {
            return dictionary
        }
        ptr += commonPrefix.utf8.count + 1
        for _ in 1..<maximumStringsPerBlock {
            let sharedPrefixLength = readVByte(&ptr)
            var bytes = commonPrefixChars.prefix(Int(sharedPrefixLength))
            let chars = ptr.assumingMemoryBound(to: CChar.self)
            var suffixLength = 0
            
            for i in 0... {
                suffixLength += 1
                if chars[i] == 0 {
                    break
                }
            }
            
            bytes.append(contentsOf: UnsafeMutableBufferPointer(start: chars, count: suffixLength))
            ptr += suffixLength
            
            commonPrefixChars = Array(bytes)
            commonPrefix = String(cString: commonPrefixChars)
            let t = try self.term(from: commonPrefix)
            let newID = nextID
            nextID += 1
            //            warn("    - TERM: \(newID): \(t)")
            dictionary[newID] = t
            if newID == id {
                return dictionary
            } else if newID >= blockMaxID {
                return dictionary
            }
        }
        
        return dictionary
    }
    
    private func readDictionaryPartition(from ptr: UnsafeMutableRawPointer, at offset: off_t, startingID: Int = 1) throws -> DictionarySectionMetadata {
        let readBuffer = ptr + Int(offset)
        
        // NOTE: HDT docs say this should be a u32, but the code says otherwise
        let d = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = UInt32(d.pointee)
        let typeLength : Int64 = 1
//        warn("dictionary type: \(type) (at offset \(offset))")
        guard type == 2 else {
            throw HDTError.error("Dictionary partition: Trying to read a CSD_PFC but type does not match: \(type)")
        }
        
        var ptr = readBuffer + Int(typeLength)
        let _c = ptr.assumingMemoryBound(to: CChar.self)
//        warn(String(format: "reading dictionary partition at offset \(offset); starting bytes: %02x %02x %02x %02x %02x", _c[0], _c[1], _c[2], _c[3], _c[4]))
        
        let stringCount = Int(readVByte(&ptr)) // numstrings
        let dataLength = Int64(readVByte(&ptr))
        let blockSize = Int(readVByte(&ptr))
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
//        warn("dictionary entries: \(stringCount)")
//        warn("dictionary byte count: \(dataLength)")
//        warn("dictionary block size: \(blockSize)")
//        warn("CRC: \(String(format: "%02x\n", Int(crc8)))")
        
        let (blocks, blocksLength) = try readSequence(from: mmappedPtr, at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
//        warn("sequence length: \(blocksLength)")
        //        warn("sequence data (\(Array(blocks).count) elements): \(Array(blocks))")
        
        let blocksArray = Array(blocks)
        let dataBlockPosition = offset + dictionaryHeaderLength + blocksLength
        let crcLength : Int64 = 4
        let length = dictionaryHeaderLength + blocksLength + dataLength + crcLength
        
        return DictionarySectionMetadata(
            count: stringCount,
            offset: offset,
            dataOffset: dataBlockPosition,
            length: length,
            blockSize: blockSize,
            startingID: startingID,
            sharedBlocks: blocksArray
        )
    }
}

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

struct TermLookupPair: Hashable {
    var position: LookupPosition
    var id: Int64
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
    var cache: [TermLookupPair: Term]
    var metadata: DictionaryMetadata
    var shared: DictionarySectionMetadata!
    var subjects: DictionarySectionMetadata!
    var predicates: DictionarySectionMetadata!
    var objects: DictionarySectionMetadata!
    public var cacheMaxItems = 2 * 1024
    var cacheReachedFullState = false
    
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    
    init(metadata: DictionaryMetadata, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer) throws {
        self.cache = [:]
        self.mmappedPtr = mmappedPtr
        self.size = size
        self.metadata = metadata
        self.rdfParser = try SerdParser(syntax: .turtle, base: "http://example.org/", produceUniqueBlankIdentifiers: false)

        var offset = metadata.offset
        
        self.shared = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += self.shared.length
        
        self.subjects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += self.subjects.length

        self.predicates = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += self.predicates.length

        self.objects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += self.objects.length
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

    private func updateCache(for lookup: TermLookupPair, dictionary: [Int64:Term]) {
        let count = cache.count
        if count == cacheMaxItems {
            if !cacheReachedFullState {
                os_signpost(.event, log: log, name: "Dictionary", "%{public}s cache reached cache maximum size of %{public}d", "\(lookup.position)", count)
            }
        } else if count > cacheMaxItems {
            cacheReachedFullState = true
            for _ in 0..<32 {
                if let k = cache.keys.randomElement() {
                    cache.removeValue(forKey: k)
                }
            }
        }
        
        for (id, v) in dictionary {
            let l = TermLookupPair(position: lookup.position, id: id)
            cache[l] = v
        }
    }
    
    private func cachedTerm(for lookup: TermLookupPair, from section: DictionarySectionMetadata) -> Term? {
        return cache[lookup]
    }
    
    private func term(for id: Int64, from section: DictionarySectionMetadata, position: LookupPosition) throws -> Term? {
        // this is a heuristic for SPO-ordered HDT files; S and P will benefit from caching,
        // but there will be lots of churn in O due to the ordering, so we don't attempt to
        // cache O values at all.
        let l = TermLookupPair(position: position, id: id)
        if position != .object, let term = cachedTerm(for: l, from: section) {
            return term
        } else {
            do {
                let dictionary = try probeDictionary(from: mmappedPtr, section: section, for: id)
                if position != .object {
                    updateCache(for: l, dictionary: dictionary)
                }
                if let term = dictionary[id] {
                    return term
                } else {
                    warn("*** Failed to lookup term for ID \(id)")
                    return nil
                }
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
            do {
                _ = try rdfParser.parse(string: "<x:> <x:> \(s) .") { (_, _, o) in
                    term = o
                }
            } catch let error {
                //                warn(">>> failed to parse string as a term: \(s)")
                throw error
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
        
        let newID = nextID
        nextID += 1
        //            warn("    - TERM: \(newID): \(t)")
        do {
            let t = try self.term(from: commonPrefix)
            dictionary[newID] = t
        } catch {
            // TODO: warn of bad term data in the dictionary
        }
        if newID == id {
            return dictionary
        } else if newID >= blockMaxID {
            return dictionary
        }
        ptr += commonPrefix.utf8.count + 1
        for _ in 1..<maximumStringsPerBlock {
            let sharedPrefixLength = readVByte(&ptr)
            let chars = ptr.assumingMemoryBound(to: CChar.self)
            var suffixLength = 0
            
            for i in 0... {
                suffixLength += 1
                if chars[i] == 0 {
                    break
                }
            }
            
            ptr += suffixLength
            
            commonPrefixChars.replaceSubrange(Int(sharedPrefixLength)..., with: UnsafeMutableBufferPointer(start: chars, count: suffixLength))
            commonPrefix = String(cString: commonPrefixChars)
            let newID = nextID
            nextID += 1
            //            warn("    - TERM: \(newID): \(t)")
            do {
                let t = try self.term(from: commonPrefix)
                dictionary[newID] = t
            } catch {
                // TODO: warn of bad term data in the dictionary
            }
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
        guard type == 2 else {
            throw HDTError.error("Dictionary partition: Trying to read a CSD_PFC but type does not match: \(type)")
        }
        
        var ptr = readBuffer + Int(typeLength)
        let stringCount = Int(readVByte(&ptr)) // numstrings
        let dataLength = Int64(readVByte(&ptr))
        let blockSize = Int(readVByte(&ptr))
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        
        let (blocks, blocksLength) = try readSequence(from: mmappedPtr, at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
        
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
            sharedBlocks: blocksArray.lazy.map { Int($0) }
        )
    }
}

import Foundation
import CoreFoundation
import SPARQLSyntax

#if os(macOS)
import os.log
import os.signpost
#endif

public struct DictionaryMetadata: CustomDebugStringConvertible {
    enum DictionaryType {
        case fourPart
    }
    
    var controlInformation: HDT.ControlInformation
    var type: DictionaryType
    var offset: off_t
    var sharedOffset: off_t
    var subjectsOffset: off_t
    var predicatesOffset: off_t
    var objectsOffset: off_t
    
    public var debugDescription: String {
        var s = ""
        print(controlInformation, to: &s)
        print("offset: \(offset)", to: &s)
        print("type: .\(type)", to: &s)
        print("shared offset: \(sharedOffset)", to: &s)
        print("subjects offset: \(subjectsOffset)", to: &s)
        print("predicates offset: \(predicatesOffset)", to: &s)
        print("objects offset: \(objectsOffset)", to: &s)
        return s
    }
}

public enum LookupPosition {
    case subject
    case predicate
    case object
}

public protocol HDTDictionaryProtocol: CustomDebugStringConvertible {
    var count: Int { get }
    var metadata: DictionaryMetadata { get }
    var simplifyBlankNodeIdentifiers: Bool { get set }
    func term(for id: Int64, position: LookupPosition) throws -> Term?
    func id(for term: Term, position: LookupPosition) throws -> Int64?
    func idSequence(for position: LookupPosition) -> AnySequence<Int64>
}

extension HDTDictionaryProtocol {
    public var controlInformation : HDT.ControlInformation {
        return metadata.controlInformation
    }
}

public final class HDTLazyFourPartDictionary : HDTDictionaryProtocol {
    #if os(macOS)
    let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
    #endif
    
    struct DictionarySectionMetadata {
        var count: Int
        var offset: off_t
        var dataOffset: off_t
        var length: Int64
        var blockSize: Int
        var startingID: Int
        var sharedBlocks: [Int64]
    }

    struct TermLookupPair: Hashable {
        var position: LookupPosition
        var id: Int64
    }
    
    var cache: [TermLookupPair: Term]
    public var metadata: DictionaryMetadata
    var shared: DictionarySectionMetadata!
    var subjects: DictionarySectionMetadata!
    var predicates: DictionarySectionMetadata!
    var objects: DictionarySectionMetadata!
    public var simplifyBlankNodeIdentifiers: Bool
    public var cacheMaxItems = 2 * 1024
    var cacheReachedFullState = false
    
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer
    
    init(metadata: DictionaryMetadata, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer) throws {
        self.cache = [:]
        self.mmappedPtr = mmappedPtr
        self.size = size
        self.metadata = metadata
        self.simplifyBlankNodeIdentifiers = false

        var offset = metadata.offset
        
        #if os(macOS)
        os_signpost(.begin, log: log, name: "Parsing Dictionary", "Read shared blocks")
        #endif
        self.shared = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += off_t(self.shared.length)
        #if os(macOS)
        os_signpost(.end, log: log, name: "Parsing Dictionary", "Read shared blocks")
        #endif

        #if os(macOS)
        os_signpost(.begin, log: log, name: "Parsing Dictionary", "Read subjects blocks")
        #endif
        self.subjects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += off_t(self.subjects.length)
        #if os(macOS)
        os_signpost(.end, log: log, name: "Parsing Dictionary", "Read subjects blocks")
        #endif

        #if os(macOS)
        os_signpost(.begin, log: log, name: "Parsing Dictionary", "Read predicates blocks")
        #endif
        self.predicates = try readDictionaryPartition(from: mmappedPtr, at: offset)
        offset += off_t(self.predicates.length)
        #if os(macOS)
        os_signpost(.end, log: log, name: "Parsing Dictionary", "Read predicates blocks")
        #endif

        #if os(macOS)
        os_signpost(.begin, log: log, name: "Parsing Dictionary", "Read objects blocks")
        #endif
        self.objects = try readDictionaryPartition(from: mmappedPtr, at: offset, startingID: 1 + shared.count)
        offset += off_t(self.objects.length)
        #if os(macOS)
        os_signpost(.end, log: log, name: "Parsing Dictionary", "Read objects blocks")
        #endif
    }
    
    public func forEach(_ body: (LookupPosition, Int64, Term) throws -> Void) throws {
        let sections : [DictionarySectionMetadata] = [predicates, objects]
        let positions : [LookupPosition] = [.predicate, .object]
        for (section, position) in zip(sections, positions) {
            try (0..<section.count).forEach { (count) in
                let id = count + section.startingID
                if let term = try term(for: Int64(id), position: position) {
                    try body(position, Int64(id), term)
                } else {
                    throw HDTError.error("Unexpectedly failed to look up term for id \(id) in section \(section)")
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
                let range = Int64(1)...Int64(self.shared.count + self.subjects.count)
                return AnyIterator(range.makeIterator())
            case .predicate:
                let range = Int64(1)...Int64(self.predicates.count)
                return AnyIterator(range.makeIterator())
            case .object:
                let range1 = Int64(1)...Int64(self.shared.count)
                let min = self.shared.count + self.subjects.count + 1
                let range2 = Int64(min)...Int64(min + self.objects.count)
                let i = ConcatenateIterator(range1.makeIterator(), range2.makeIterator())
                return AnyIterator(i)
            }
        }
    }

    private func updateCache(for lookup: TermLookupPair, dictionary: [Int64:Term]) {
        let count = cache.count
        if count == cacheMaxItems {
            if !cacheReachedFullState {
                #if os(macOS)
                os_signpost(.event, log: log, name: "Dictionary", "%{public}s cache reached cache maximum size of %{public}d", "\(lookup.position)", count)
                #endif
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
        if !simplifyBlankNodeIdentifiers, position != .object, let term = cachedTerm(for: l, from: section) {
            return term
        } else {
            do {
                let dictionary = try probeDictionary(from: mmappedPtr, section: section, for: id)
                if !simplifyBlankNodeIdentifiers, position != .object {
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

    private func string(from term: Term) throws -> String {
        switch term.type {
        case .iri:
            return term.value
        case .blank:
            return "_:\(term.value)"
        case .language(let l):
            return "\"\(term.value)\"@\(l)"
        case .datatype(let dt):
            return "\"\(term.value)\"^^<\(dt.value)>"
        }
    }
    
    private func unicodeUnescaped(_ orig: String) -> String {
        var s = orig
        // unescape \u and \U hex codes
        let input = s as NSString
        let unescaped : CFMutableString = input.mutableCopy() as! CFMutableString
        let transform = "Any-Hex/C".mutableCopy() as! CFMutableString
        CFStringTransform(unescaped, nil, transform, true)
        #if os(macOS)
        s = unescaped as String
        #else
        let nss = "\(unescaped)"
        s = nss as String
        #endif
        return s
    }
    
    private func unicodeEscaped(_ orig: String) -> String {
        var s = orig
        // escape \u and \U hex codes
        let input = s as NSString
        let unescaped : CFMutableString = input.mutableCopy() as! CFMutableString
        let transform = "Any-Hex/C".mutableCopy() as! CFMutableString
        CFStringTransform(unescaped, nil, transform, false)
        #if os(macOS)
        s = unescaped as String
        #else
        let nss = "\(unescaped)"
        s = nss as String
        #endif
        return s
    }
    
    private func term(from orig: String, for id: HDT.TermID) throws -> Term {
        /**
         
         Strings may have \u and \U escaping. After unescaping:
         
         * Strings starting with "_:" are blank nodes
         * Strings starting with a double quote are literals; their value ends with a double quote, and have optional datatype or language tags
         * Anything else is an IRI
         
         **/

        var s = orig
        if s.contains("\\") {
            s = unicodeUnescaped(s)
        }

        guard let first = s.unicodeScalars.first else {
            return Term(iri: "")
        }
        
        if s.hasPrefix("_:") {
            if simplifyBlankNodeIdentifiers {
                return Term(value: "b\(id)", type: .blank)
            } else {
                return Term(value: String(s.dropFirst(2)), type: .blank)
            }
        } else if s.hasPrefix("\"") { // literal starting with a double quote
            let i = s.lastIndex(of: "\"")!
            let value = s.dropFirst().prefix(upTo: i)
            let suffix = s[i...].dropFirst()
            if suffix.hasPrefix("^^<") {
                let dtIRI = String(suffix.dropFirst(3).dropLast())
                let dt = TermDataType(stringLiteral: dtIRI)
                return Term(value: String(value), type: .datatype(dt))
            } else if suffix.hasPrefix("@") {
                let lang = String(suffix.dropFirst())
                return Term(value: String(value), type: .language(lang))
            } else {
                return Term(string: String(value))
            }
        } else if first == Unicode.Scalar(0x22) { // literal starting with a double quote with a combining character
            let scalars = Array(s.unicodeScalars)
            let i = scalars.lastIndex(of: Unicode.Scalar(0x22))!
            let value = String.UnicodeScalarView(scalars.dropFirst().prefix(upTo: i))
            let suffixScalars = String.UnicodeScalarView(scalars[i...].dropFirst())
            let suffix = String(suffixScalars)
            if suffix.hasPrefix("^^<") {
                let dtIRI = String(suffix.dropFirst(3).dropLast())
                let dt = TermDataType(stringLiteral: dtIRI)
                return Term(value: String(value), type: .datatype(dt))
            } else if suffix.hasPrefix("@") {
                let lang = String(suffix.dropFirst())
                return Term(value: String(value), type: .language(lang))
            } else {
                return Term(string: String(value))
            }
        } else { // IRI
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
        nextID += Int64(skipBlocks) * Int64(maximumStringsPerBlock)
        
        let blockMaxID = (section.startingID + section.count - 1)
        let blocksSuffix = blocks.dropFirst(skipBlocks)
        let blockIndex = blocksSuffix.startIndex
        let blockOffset = Int(blocksSuffix[blockIndex])
        var ptr = readBuffer + blockOffset
        let charsPtr = ptr.assumingMemoryBound(to: CChar.self)
        
        var commonPrefix = String(cString: charsPtr)
        let charsBufferPtr = UnsafeBufferPointer(start: charsPtr, count: commonPrefix.utf8.count)
        var commonPrefixChars = Array(charsBufferPtr)
        
        let newID = nextID
        nextID += 1
        //            warn("    - TERM: \(newID): \(t)")
        do {
            let t = try self.term(from: commonPrefix, for: newID)
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
            
            if sharedPrefixLength <= commonPrefixChars.count {
                let replacementRange = Int(sharedPrefixLength)..<commonPrefixChars.endIndex
                commonPrefixChars.replaceSubrange(replacementRange, with: UnsafeMutableBufferPointer(start: chars, count: suffixLength))
            } else {
//                warn("offset=\(offset+Int64(blockOffset))")
                throw HDTError.error("Previous term string is not long enough to use declared shared prefix (\(commonPrefixChars.count) < \(sharedPrefixLength))")
            }
            commonPrefix = String(cString: commonPrefixChars)
            let newID = nextID
            nextID += 1
//                        warn("    - TERM: \(newID): \(commonPrefix)")
            do {
                let t = try self.term(from: commonPrefix, for: newID)
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
        
//        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        
        let (blocksArray, blocksLength) = try readSequenceImmediate(from: mmappedPtr, at: offset + off_t(dictionaryHeaderLength), assertType: 1)
        
        ptr += Int(blocksLength)
        
        let dataBlockPosition = offset + off_t(dictionaryHeaderLength) + off_t(blocksLength)
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

extension HDTLazyFourPartDictionary: CustomDebugStringConvertible {
    public var debugDescription: String {
        var s = ""
        print(metadata, terminator: "", to: &s)
        return s
    }
}

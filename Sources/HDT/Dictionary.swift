import Foundation
import SPARQLSyntax

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
}

public final class HDTLazyFourPartDictionary : HDTDictionaryProtocol, FileBased {
    struct DictionarySectionMetadata {
        var count: Int
        var offset: Int64
        var dataOffset: Int64
        var length: Int64
        var blockSize: Int
        var startingID: Int
        var sharedBlocks: [Int]
    }
    
    public var state: FileState
    var cache: [LookupPosition: [Int64: Term]]
    var metadata: DictionaryMetadata
    var shared: DictionarySectionMetadata!
    var subjects: DictionarySectionMetadata!
    var predicates: DictionarySectionMetadata!
    var objects: DictionarySectionMetadata!
    public var cacheMaxSize = 128 * 1024
    
    init(metadata: DictionaryMetadata, state: FileState) throws {
        self.cache = [.subject: [:], .predicate: [:], .object: [:]]
        self.metadata = metadata
        self.state = state
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        
        let size = 256 * 1024 * 1024 // TODO: this should not be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, metadata.offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary") }
        
        var offset = metadata.offset
        
        warn("reading dictionary: shared at \(offset)")
        self.shared = try readDictionaryPartition(at: offset)
        offset += self.shared.length
        warn("read \(shared.count) shared terms")
        
        warn("offset: \(offset)")
        
        warn("reading dictionary: subjects at \(offset)")
        self.subjects = try readDictionaryPartition(at: offset, startingID: 1 + shared.count)
        offset += self.subjects.length
        warn("read \(subjects.count) subject terms")
        
        warn("reading dictionary: predicates at \(offset)")
        self.predicates = try readDictionaryPartition(at: offset)
        offset += self.predicates.length
        warn("read \(predicates.count) predicate terms")
        
        warn("reading dictionary: objects at \(offset)")
        self.objects = try readDictionaryPartition(at: offset, startingID: 1 + shared.count)
        offset += self.objects.length
        warn("read \(objects.count) object terms")
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
        warn("lazy lookup of \(position): \(id)")
        switch position {
        case .subject:
            if id <= shared.count {
                warn("find term \(id) in shared section")
                return try term(for: id, from: shared, position: position)
            } else {
                warn("find term \(id) in subjects section")
                return try term(for: id, from: subjects, position: position)
            }
        case .predicate:
            warn("find term \(id) in predicates section")
            return try term(for: id, from: predicates, position: position)
        case .object:
            if id <= shared.count {
                warn("find term \(id) in shared section")
                return try term(for: id, from: shared, position: position)
            } else {
                warn("find term \(id) in objects section")
                return try term(for: id, from: objects, position: position)
            }
        }
    }

    private func updateCache(for id: Int64, position: LookupPosition, dictionary: [Int64:Term]) {
        let count = cache[position]!.count
        if count > cacheMaxSize {
            if let k = cache[position]!.keys.randomElement() {
                print("removing cache key: \(k)")
                cache[position]!.removeValue(forKey: k)
            }
        }
        
        cache[position]?.merge(dictionary, uniquingKeysWith: { (a, b) in a })
        print("\(position) cache has \(cache[position]?.count ?? 0) items")
    }
    
    private func term(for id: Int64, from section: DictionarySectionMetadata, position: LookupPosition) throws -> Term? {
        if let positionCache = cache[position], let term = positionCache[id] {
            return term
        } else {
            let dictionary = try probeDictionary(section: section, for: id)
            updateCache(for: id, position: position, dictionary: dictionary)
            let term = dictionary[id]
            cache[position]?[id] = term
            return term
        }
    }
    
    private func probeDictionary(section: DictionarySectionMetadata, for id: Int64) throws -> [Int64: Term] {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        
        let generator = AnyIterator(sequence(first: Int64(section.startingID)) { $0 + 1 })
        let bufferBlocks = section.sharedBlocks
        let offset = section.dataOffset
        let size = Int(section.length)
        let count = section.count
        let maximumStringsPerBlock = section.blockSize
        
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r >= size else { throw HDTError.error("Not enough bytes read for HDT dictionary buffer blocks") }
        var generated : Int64 = 0
        var dictionary = [Int64: Term]()
        enum ProbeStatus {
            case stop
            case seenID
            case keepGoing
        }
        let generateTerm = { (s: String) -> ProbeStatus in
            let termID = generator.next()!
            generated += 1
            let newID = termID
            warn("    - TERM: \(newID): \(s)")
            
            if s.hasPrefix("_:") {
                dictionary[newID] = Term(value: String(s.dropFirst(2)), type: .blank)
            } else if s.hasPrefix("\"") {
                dictionary[newID] = Term(string: String(s.dropFirst().dropLast()))
                
                if s.contains("\"@") {
                    warn("TODO: handle language literals")
                } else if s.contains("\"^^") {
                    warn("TODO: handle datatype literals")
                }
            } else {
                dictionary[newID] = Term(iri: s)
            }
            if newID == id {
                return .seenID
            } else if newID >= (section.startingID + section.count - 1) {
                return .stop
            } else {
                return .keepGoing
            }
        }
        
        var stop = false


        var ptr = readBuffer
        let blocks = section.sharedBlocks
        
        let localIDOffset = id - Int64(section.startingID)
        let skipBlocks = Int(localIDOffset/Int64(maximumStringsPerBlock))
        warn("there are \(blocks.count) blocks")
        warn("skipping \(skipBlocks) blocks to get to ID \(id) (\(maximumStringsPerBlock) strings per block)")
        warn("this section has:")
        warn("    count: \(section.count)")
        warn("    IDs \(section.startingID)...\(section.startingID+section.count-1)")
        for _ in blocks.prefix(skipBlocks) {
            for _ in 0..<maximumStringsPerBlock {
                _ = generator.next()
            }
        }
        
//        warn("\(blocks)")
        BLOCK_LOOP: for blockIndex in blocks.dropFirst(skipBlocks).indices {
//            print("BLOCK >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>")
//        for blockIndex in blocks.indices {
            let blockOffset = blocks[blockIndex]
            warn("==> block offset: \(blockOffset)")
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
            let status = generateTerm(commonPrefix)
            switch status {
            case .stop:
                break BLOCK_LOOP
            case .seenID:
                stop = true
            default:
                break
            }
            ptr += commonPrefix.utf8.count + 1
            for _ in 1..<maximumStringsPerBlock {
//                print("block item ---------------------------")
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
//                print("=======================")
                for i in 0... {
                    suffixLength += 1
                    bytes.append(chars[i])
//                    print(">>> suffix byte: \(chars[i]); \(String(format: "%02x (%c)", chars[i], chars[i]))")
                    if chars[i] == 0 {
                        break
                    }
                }
                ptr += suffixLength
                //                warn("-- suffix length: \(suffixLength)")
                
                commonPrefix = String(cString: bytes)
                let status = generateTerm(commonPrefix)
                switch status {
                case .stop:
                    break BLOCK_LOOP
                case .seenID:
                    stop = true
                default:
                    break
                }

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
                        print("last term string: \(commonPrefix)")
                        print("char bytes: \(bytes)")
                        print("shared prefix length: \(sharedPrefixLength)")
                        print("suffix length: \(suffixLength)")
                        assert(false)
                    }
                    let dist = readBuffer.distance(to: ptr)
                    if dist > next {
                        print("A: \(dist) <= \(next)")
                    }
                    assert(dist <= next)
                }
                if generated > count {
                    print("B: \(generated) <= \(count)")
                }
                assert(generated <= count)
            }
            if stop {
                break
            }
        }
        
        warn("\(dictionary)")
        return dictionary
    }
    
    private func readDictionaryPartition(at offset: off_t, startingID: Int = 1) throws -> DictionarySectionMetadata {
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
        let dataLength = Int64(readVByte(&ptr))
        let blockSize = Int(readVByte(&ptr))
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        ptr += 1
        // TODO: verify CRC
        
        let dictionaryHeaderLength = Int64(readBuffer.distance(to: ptr))
        warn("dictionary entries: \(stringCount)")
        warn("dictionary byte count: \(dataLength)")
        warn("dictionary block size: \(blockSize)")
        warn("CRC: \(String(format: "%02x\n", Int(crc8)))")
        
        let (blocks, blocksLength) = try readSequence(at: offset + dictionaryHeaderLength, assertType: 1)
        ptr += Int(blocksLength)
        warn("sequence length: \(blocksLength)")
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

public struct HDTDictionary : HDTDictionaryProtocol {
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

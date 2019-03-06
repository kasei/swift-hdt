import Foundation
import SPARQLSyntax

#if os(macOS)
import os.log
import os.signpost
#endif

public enum HDTError: Error {
    case error(String)
}

public struct HeaderMetadata: CustomDebugStringConvertible {
    var controlInformation: HDT.ControlInformation
    var rdfContent: String
    var offset: off_t
    
    public var debugDescription: String {
        var s = ""
        print(controlInformation, to: &s)
        print("offset: \(offset)", to: &s)
        print("rdf payload:\n\(rdfContent)", to: &s)
        // If we wanted to have Kineo be a dependency, we could pretty-print the payload:
//        do {
//            let par = RDFParser(syntax: .turtle, base: "", produceUniqueBlankIdentifiers: false)
//            var triples = [Triple]()
//            try par.parse(string: rdfContent) { (s, p, o) in
//                triples.append(Triple(subject: s, predicate: p, object: o))
//            }
//            let prefixes = [
//                "hdt": Term(iri: "http://purl.org/HDT/hdt#"),
//                "dc": Term(iri: "http://purl.org/dc/terms/"),
//                "void": Term(iri: "http://rdfs.org/ns/void#"),
//                ]
//
//            let ser = TurtleSerializer(prefixes: prefixes)
//            try ser.serialize(triples, to: &s)
//        } catch let error {
//            print("*** Failed to parse header RDF: \(error)", to: &s)
//        }
        return s
    }
}

public class HDT {
    public typealias TermID = Int64
    public typealias IDTriple = (TermID, TermID, TermID)
    
    var filename: String
    var header: HeaderMetadata
    var triplesMetadata: TriplesMetadata
    var dictionaryMetadata: DictionaryMetadata
    var size: Int
    var mmappedPtr: UnsafeMutableRawPointer

    public var state: FileState
    public var simplifyBlankNodeIdentifiers: Bool
    public var controlInformation: ControlInformation

    #if os(macOS)
    let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
    #endif

    public struct ControlInformation: CustomDebugStringConvertible {
        public enum ControlType : UInt8 {
            case unknown = 0
            case global = 1
            case header = 2
            case dictionary = 3
            case triples = 4
            case index = 5
        }
        
        var type: ControlType
        var format: String
        var properties: [String:String]
        var crc: UInt16
        
        var triplesCount: Int? {
            guard let countNumber = properties["numTriples"], let count = Int(countNumber) else {
                return nil
            }
            return count
        }
        
        var tripleOrdering: TripleOrdering? {
            guard let orderNumber = properties["order"], let i = Int(orderNumber), let order = TripleOrdering(rawValue: i) else {
                return nil
            }
            return order
        }
        
        public var debugDescription: String {
            return """
            ControlInformation(
                type: .\(type),
                format: "\(format)",
                properties: \(properties),
                crc: \(String(format: "0x%02x", crc))
            )
            """
        }
    }
    
    init(filename: String, size: Int, ptr mmappedPtr: UnsafeMutableRawPointer, control ci: ControlInformation, header: HeaderMetadata, triples: TriplesMetadata, dictionary: DictionaryMetadata) throws {
        self.filename = filename
        self.size = size
        self.mmappedPtr = mmappedPtr
        self.header = header
        self.triplesMetadata = triples
        self.dictionaryMetadata = dictionary
        self.controlInformation = ci
        self.simplifyBlankNodeIdentifiers = false
        
        self.state = .none
    }
    
    deinit {
        munmap(mmappedPtr, size)
    }
    
    func term(for id: Int64, position: LookupPosition) throws -> Term? {
        let dictionary = try hdtDictionary()
        return try dictionary.term(for: id, position: position)
    }
    
    func id(for term: Term, position: LookupPosition) throws -> Int64? {
        let dictionary = try hdtDictionary()
        return try dictionary.id(for: term, position: position)
    }

    func triplesSection() throws -> HDTTriples {
        switch self.triplesMetadata.format {
        case .bitmap:
            let t = try HDTBitmapTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
            return t
        case .list:
            let t = try HDTListTriples(metadata: triplesMetadata, size: size, ptr: mmappedPtr)
            return t
        }
    }
    
    func readIDTriples(at offset: off_t, dictionary: HDTDictionaryProtocol, restrict restriction: IDRestriction) throws -> (Int64, AnyIterator<IDTriple>) {
        
        switch self.triplesMetadata.format {
        case .bitmap:
            guard let t = try triplesSection() as? HDTBitmapTriples else {
                throw HDTError.error("Unexpected triples section type in readIDTriples")
            }
            let ids = dictionary.idSequence(for: .subject) // TODO: this should be based on the first position in the HDT ordering
            let (count, triples) = try t.idTriples(ids: ids, restrict: restriction)
            return (count, triples)
        case .list:
            guard let t = try triplesSection() as? HDTListTriples else {
                throw HDTError.error("Unexpected triples section type in readIDTriples")
            }
            return try t.idTriples(restrict: restriction)
        }
    }

    func readDictionary(at offset: off_t) throws -> HDTDictionaryProtocol {
        switch dictionaryMetadata.type {
        case .fourPart:
            let d = try HDTLazyFourPartDictionary(metadata: dictionaryMetadata, size: size, ptr: mmappedPtr)
            return d
        }
    }
}

extension HDT: CustomDebugStringConvertible {
    public var debugDescription: String {
        do {
            var s = ""
            print("HDT:", to: &s)
            print(controlInformation, to: &s)
            print("", to: &s)
            
            print("Header:", to: &s)
            print(header, to: &s)

            print("Dictionary:", to: &s)
            let dictionary = try hdtDictionary()
            print(dictionary, to: &s)
            print("", to: &s)
            
            print("Triples:", to: &s)
            let t = try triplesSection()
            print(t, to: &s)
            
            return s
        } catch {
            return "(*** error describing HDT ***)"
        }
    }
}

public extension HDT {
    private class HDTTriplesIterator<I: IteratorProtocol>: IteratorProtocol where I.Element == Triple {
        var hdt: HDT
        var triples: I
        
        init(hdt: HDT, triples: I) {
            self.hdt = hdt
            self.triples = triples
        }
        
        func next() -> Triple? {
            return triples.next()
        }
    }
    
    func hdtDictionary() throws -> HDTDictionaryProtocol {
        var dictionary = try readDictionary(at: self.dictionaryMetadata.offset)
        dictionary.simplifyBlankNodeIdentifiers = self.simplifyBlankNodeIdentifiers
        return dictionary
    }
    
    // TODO: add code to support loading directly into a kineo model using:
    //           MemoryQuadStore.load(version:dictionary:quads:)
    //       materialize predicates and then re-map subjects/objects that
    //       appear as predicates to their predicate ID values.
    //       use high bits to separate ID spaces of predicates and subject/objects
    
    public func triples() throws -> AnyIterator<Triple> {
        let dictionary = try hdtDictionary()
        #if os(macOS)
        os_signpost(.begin, log: log, name: "Triples", "Read ID Triples")
        #endif
        let (_, tripleIDs) = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: (nil, nil, nil))
        #if os(macOS)
        os_signpost(.end, log: log, name: "Triples", "Read ID Triples")
        #endif

        #if os(macOS)
        os_signpost(.begin, log: log, name: "Triples", "Materializing")
        #endif
        let triples = tripleIDs.lazy.compactMap { self.mapToTriple(ids: $0, from: dictionary) }
        #if os(macOS)
        os_signpost(.end, log: log, name: "Triples", "Materializing")
        #endif

        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    private func mapToTriple(ids t: IDTriple, from dictionary: HDTDictionaryProtocol) -> Triple? {
        do {
            guard let s = try dictionary.term(for: t.0, position: .subject) else {
                warn("failed to load term for subject \(t.0)")
                return nil
            }
            guard let p = try dictionary.term(for: t.1, position: .predicate) else {
                warn("failed to load term for predicate \(t.1)")
                return nil
            }
            guard let o = try dictionary.term(for: t.2, position: .object) else {
                warn("failed to load term for object \(t.2)")
                return nil
            }
            return Triple(subject: s, predicate: p, object: o)
        } catch let error {
            warn(">>> error mapping IDs to triple: \(error)")
            return nil
        }
    }
    
    private func triples(dictionary: HDTDictionaryProtocol, restrict restriction: IDRestriction) throws -> AnyIterator<Triple> {
        let order = self.triplesMetadata.ordering
        guard case .spo = order else {
            throw HDTError.error("TriplePattern matching on non-SPO ordered triples is unimplemented") // TODO
        }
        let (_, tripleIDs) = try readIDTriples(at: self.triplesMetadata.offset, dictionary: dictionary, restrict: restriction)
        let triples = tripleIDs.lazy
            .filter {
                if let s = restriction.0, s != $0.0 {
                    return false
                }
                if let p = restriction.1, p != $0.1 {
                    return false
                }
                if let o = restriction.2, o != $0.2 {
                    return false
                }
                return true
            }
            .compactMap { self.mapToTriple(ids: $0, from: dictionary) }

        let i = HDTTriplesIterator(hdt: self, triples: triples.makeIterator())
        return AnyIterator(i)
    }
    
    public func triples(matching tp: TriplePattern) throws -> AnyIterator<Triple> {
        let dictionary = try hdtDictionary()
        
        var restrictions = [LookupPosition:Int64]()
        var variables = [LookupPosition:String]()
        
        let pairs = zip([LookupPosition.subject, .predicate, .object], tp)
        for  (pos, node) in pairs {
            switch node {
            case .bound(let term):
                if let id = try dictionary.id(for: term, position: pos) {
                    restrictions[pos] = id
                } else {
                    return AnyIterator([].makeIterator())
                }
            case .variable(let name, binding: _):
                variables[pos] = name
            }
        }

        let order = self.triplesMetadata.ordering
        guard case .spo = order else {
            throw HDTError.error("TriplePattern matching on non-SPO ordered triples is unimplemented") // TODO: ensure the restriction tuples below are properly ordered for the current HDT ordering
        }
        
        let boundPositions = Set(restrictions.keys)
        switch boundPositions {
        case [.subject]:
            let x = restrictions[.subject]!
            return try triples(dictionary: dictionary, restrict: (x, nil, nil))
        case [.subject, .predicate]:
            let x = restrictions[.subject]!
            let y = restrictions[.predicate]!
            return try triples(dictionary: dictionary, restrict: (x, y, nil))
        case [.subject, .predicate, .object]:
            let x = restrictions[.subject]!
            let y = restrictions[.predicate]!
            let z = restrictions[.object]!
            return try triples(dictionary: dictionary, restrict: (x, y, z))
        case []:
            return try triples()
        default:
            throw HDTError.error("TriplePattern matching cannot be performed on a pattern that requires an index other than \(order)")
        }
    }
}

public class HDTRDFParser: RDFParser {
    public enum Error: Swift.Error {
        case invalid
    }
    
    public var mediaTypes: Set<String>
    public static var canonicalMediaType = "application/hdt"
    public static var canonicalFileExtensions = [".hdt"]
    required public init() {
        mediaTypes = [HDTRDFParser.canonicalMediaType]
    }
    
//    public static func register() {
//        RDFSerializationConfiguration.shared.registerParser(self, withType: HDTRDFParser.canonicalMediaType, extensions: HDTRDFParser.canonicalFileExtensions, mediaTypes: [])
//    }
    
    public func parse(string: String, mediaType: String, base: String? = nil, handleTriple: @escaping TripleHandler) throws -> Int {
        throw Error.invalid
    }
    
    public func parseFile(_ filename: String, mediaType: String, base: String? = nil, handleTriple: @escaping TripleHandler) throws -> Int {
        let p = try HDTParser(filename: filename)
        let hdt = try p.parse()
        let triples = try hdt.triples()
        var count = 0
        for t in triples {
            handleTriple(t.subject, t.predicate, t.object)
            count += 1
        }
        return count
    }
}

public class HDTSerializer {
    public var mediaTypes: Set<String>
    public static var canonicalMediaType = "application/hdt"
    required public init() {
        mediaTypes = [HDTRDFParser.canonicalMediaType]
    }

    enum DictPosition {
        case so
        case p
    }
    struct DictDirections {
        var t2i: [String: Int]
        var i2t: [Int: String]
    }
    private typealias TermDict = [DictPosition: DictDirections]
    public func serialize<S: Sequence>(_ triples: S) throws -> Data where S.Element == Triple {
        let (dictionary, shared, subjs, preds, objs) = computeDictionary(triples)
        let idTriples = computeTriples(triples, dictionary: dictionary)

        print("*** Using hard-coded header content")
        let content    = "<file:///Users/greg/foaf.ttl> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://purl.org/HDT/hdt#Dataset> .\n<file:///Users/greg/foaf.ttl> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://rdfs.org/ns/void#Dataset> .\n<file:///Users/greg/foaf.ttl> <http://rdfs.org/ns/void#triples> \"413\" .\n<file:///Users/greg/foaf.ttl> <http://rdfs.org/ns/void#properties> \"73\" .\n<file:///Users/greg/foaf.ttl> <http://rdfs.org/ns/void#distinctSubjects> \"60\" .\n<file:///Users/greg/foaf.ttl> <http://rdfs.org/ns/void#distinctObjects> \"355\" .\n<file:///Users/greg/foaf.ttl> <http://purl.org/HDT/hdt#formatInformation> \"_:format\" .\n_:format <http://purl.org/HDT/hdt#dictionary> \"_:dictionary\" .\n_:format <http://purl.org/HDT/hdt#triples> \"_:triples\" .\n<file:///Users/greg/foaf.ttl> <http://purl.org/HDT/hdt#statisticalInformation> \"_:statistics\" .\n<file:///Users/greg/foaf.ttl> <http://purl.org/HDT/hdt#publicationInformation> \"_:publicationInformation\" .\n_:dictionary <http://purl.org/dc/terms/format> <http://purl.org/HDT/hdt#dictionaryFour> .\n_:dictionary <http://purl.org/HDT/hdt#dictionarynumSharedSubjectObject> \"58\" .\n_:dictionary <http://purl.org/HDT/hdt#dictionarysizeStrings> \"8790\" .\n_:triples <http://purl.org/dc/terms/format> <http://purl.org/HDT/hdt#triplesBitmap> .\n_:triples <http://purl.org/HDT/hdt#triplesnumTriples> \"413\" .\n_:triples <http://purl.org/HDT/hdt#triplesOrder> \"SPO\" .\n_:statistics <http://purl.org/HDT/hdt#hdtSize> \"9544\" .\n_:publicationInformation <http://purl.org/dc/terms/issued> \"2018-12-11T19:56Z\" .\n_:statistics <http://purl.org/HDT/hdt#originalSize> \"45227\" .\n";

        return writeHDT(header: content, dictionary: dictionary, triples: idTriples, sharedIDs: shared, subjectIDs: subjs, predicateIDs: preds, objectIDs: objs)
    }
    
    public func serialize<T: TextOutputStream, S: Sequence>(_ triples: S, to stream: inout T) throws where S.Element == Triple {
        fatalError("Cannot write binary HDT to a TextOutputStream")
    }
}

extension HDTSerializer {
    private func termToString(_ term: Term) -> String {
        switch term.type {
        case .blank:
            return "_:\(term.value)"
        case .datatype(TermDataType.string):
            return "\"\(term.value)\""
        case .datatype(let dt):
            return "\"\(term.value)\"^^<\(dt.value)>"
        case .language(let lang):
            return "\"\(term.value)\"@\(lang)"
        case .iri:
            return term.value
        }
    }
    
    private func idForTerm(dictionary: TermDict, term: Term, position: DictPosition) -> Int? {
        let d = dictionary[position]!
        let s = termToString(term)
        let id = d.t2i[s]
        return id
    }
    
    private func sortStringByBytes<S: Sequence>(_ values: S) -> [String] where S.Element == String {
        let sorted = values.sorted { (l, r) -> Bool in
            return strcmp(l, r) == -1
//            l.data(using: .utf8)!.toHexString() < r.data(using: .utf8)!.toHexString()
        }
        return sorted
    }
    
    private func computeDictionary<S: Sequence>(_ triples: S) -> (TermDict, [Int], [Int], [Int], [Int]) where S.Element == Triple {
        var subjects = [String:Term]()
        var predicates = [String:Term]()
        var objects = [String:Term]()
        for t in triples {
            subjects[termToString(t.subject)] = t.subject
            predicates[termToString(t.predicate)] = t.predicate
            objects[termToString(t.object)] = t.object
        }
        
        let ss = Set(subjects.keys)
        let os = Set(objects.keys)
        let shared = Dictionary(uniqueKeysWithValues: ss.intersection(os).map({ (s) -> (String, Term) in
            (s, subjects[s]!)
        }))
        
        var next_so = 1
        var next_p = 1
        var dictionary : TermDict = [
            .so: DictDirections(t2i: [:], i2t: [:]),
            .p: DictDirections(t2i: [:], i2t: [:]),
            ]
        
        var shared_ids = Set<Int>()
        var subj_ids = Set<Int>()
        var pred_ids = Set<Int>()
        var obj_ids = Set<Int>()
        
        for termString in sortStringByBytes(shared.keys) {
            let id = next_so
            next_so += 1
            shared_ids.insert(id)
            dictionary[.so]!.t2i[termString] = id
            dictionary[.so]!.i2t[id] = termString
        }
        
        for termString in sortStringByBytes(subjects.keys.filter({ shared[$0] == nil })) {
            let id = next_so
            next_so += 1
            subj_ids.insert(id)
            dictionary[.so]!.t2i[termString] = id
            dictionary[.so]!.i2t[id] = termString
        }
        
        for termString in sortStringByBytes(predicates.keys) {
            let id = next_p
            next_p += 1
            pred_ids.insert(id)
            dictionary[.p]!.t2i[termString] = id
            dictionary[.p]!.i2t[id] = termString
        }
        
        for termString in sortStringByBytes(objects.keys.filter({ shared[$0] == nil })) {
            let id = next_so
            next_so += 1
            obj_ids.insert(id)
            dictionary[.so]!.t2i[termString] = id
            dictionary[.so]!.i2t[id] = termString
        }
        
        return (dictionary, shared_ids.sorted(), subj_ids.sorted(), pred_ids.sorted(), obj_ids.sorted())
    }
    
    private func computeTriples<S: Sequence>(_ triples: S, dictionary: TermDict) -> [(Int, Int, Int)] where S.Element == Triple {
        var idTriples = [(Int, Int, Int)]()
        for t in triples {
            guard let sid = idForTerm(dictionary: dictionary, term: t.subject, position: .so) else { fatalError("uh oh") }
            guard let pid = idForTerm(dictionary: dictionary, term: t.predicate, position: .p) else { fatalError("uh oh") }
            guard let oid = idForTerm(dictionary: dictionary, term: t.object, position: .so) else { fatalError("uh oh") }
            idTriples.append((sid, pid, oid))
        }
        
        let sortedTriples = idTriples.sorted { (lhs, rhs) -> Bool in
            lhs < rhs
        }
        
        return sortedTriples
    }
    
    private func writeHDT<S: Sequence>(header content: String, dictionary: TermDict, triples: [(Int, Int, Int)], sharedIDs: S, subjectIDs: S, predicateIDs: S, objectIDs: S) -> Data where S.Element == Int {
//        let so = dictionary[.so]!.i2t
//        let p = dictionary[.p]!.i2t
//        print("# Graph terms:")
//        for id in so.keys.sorted() {
//            print(String(format: "%6d: %@", id, so[id]!))
//        }
//        print("# Predicates:")
//        for id in p.keys.sorted() {
//            print(String(format: "%6d: %@", id, p[id]!))
//        }

        let ci = writeControlInformation(.global, format: "<http://purl.org/HDT/hdt#HDTv1>", properties: [:])
        let h = writeHeader(content: content)
        let d = writeDictionary(dictionary: dictionary, sharedIDs: Array(sharedIDs), subjectIDs: Array(subjectIDs), predicateIDs: Array(predicateIDs), objectIDs: Array(objectIDs))
        let t = writeTriples(triples)
        let data = ci + h + d + t
        return data
    }
    
    private func writeBitmap(_ bits: [Bool]) -> Data {
        let left = 8 - (bits.count % 8)
        let padding = [Bool](repeating: false, count: left)
        var bits = bits + padding
        guard bits.count % 8 == 0 else { fatalError() }
        let format : UInt8 = 1
        
        var data = Data()
        data.append(format)
        data.append(vByte(bits.count))
        data.append(data.crc8Data)
        
        var bitsData = Data()
        while !bits.isEmpty {
            var v : UInt8 = 0
            for _ in 0..<8 {
                let b = bits.remove(at: 0)
                if b {
                    v |= 1
                }
                v <<= 1
            }
            bitsData.append(v)
        }
        
        data.append(bitsData)
        data.append(bitsData.crc32Data)
        return data
    }
    
    private func writeArray(_ values: [Int]) -> Data {
//        let type: UInt8 = 1
        var data = Data()
//        data.append(type)
//        data.append(vByte(values.count))
//        data.append(data.crc8Data)
        let seqData = writeSequence(values)
        data.append(seqData)
//        data.append(seqData.crc32Data)
        return data
    }
    
    private func writeTriplesBitmap(_ triples: [(Int, Int, Int)]) -> Data {
        let ordering = TripleOrdering.spo.rawValue
        let props = ["order": "\(ordering)", "numTriples": "\(triples.count)"]
        let ci = writeControlInformation(.triples, format: "<http://purl.org/HDT/hdt#triplesBitmap>", properties: props)

        var bitmap_y = [Bool]()
        var bitmap_z = [Bool]()
        var array_y = [Int]()
        var array_z = [Int]()
        var tree : [Int: [Int: [Int]]] = [:]
        
        for t in triples {
            tree[t.0, default: [:]][t.1, default: []].append(t.2)
        }
        for s in tree.keys.sorted() {
            let po = tree[s]!
            for p in po.keys.sorted() {
                array_y.append(p)
                bitmap_y.append(false)
                for o in po[p]! {
                    array_z.append(o)
                    bitmap_z.append(false)
                }
                bitmap_z.removeLast()
                bitmap_z.append(true)
            }
            bitmap_y.removeLast()
            bitmap_y.append(true)
        }
        
        let by = writeBitmap(bitmap_y)
        let bz = writeBitmap(bitmap_z)
        let ay = writeArray(array_y)
        let az = writeArray(array_z)
        return ci + by + bz + ay + az
    }

    private func writeTriples(_ triples: [(Int, Int, Int)]) -> Data {
        return writeTriplesBitmap(triples)
    }
    
    private func writeDictionaryBlock(blockSize: Int, dictionary: TermDict, position: DictPosition, ids: inout [Int]) -> Data {
        let first = ids.remove(at: 0)
        var current = dictionary[position]!.i2t[first]!
        
        var block = Data()
        block.append(current.data(using: .utf8)!)
        block.append(0x00)
//        print("first (\(current.utf8.count)): \(current)")

        while !ids.isEmpty {
            let id = ids.remove(at: 0)
            let term = dictionary[position]!.i2t[id]!
            let prefix = current.commonPrefix(with: term)
            let l = prefix.utf8.count
            let trailing = term.utf8.count - l
            let suffix = term.suffix(trailing)
//            print("value (\(trailing)): \(prefix)|\(suffix)")
            block.append(vByte(l))
            block.append(suffix.data(using: .utf8)!)
            block.append(0x00)
            current = term
        }
        
        return block
    }
    
    private func vByte(_ value: Int) -> Data {
        var value = value
        var bytes = [UInt8]()
        let v = UInt8(value & 0x7f)
        bytes.append(v)
        value >>= 7
        
        while value > 0 {
            let v = UInt8(value & 0x7f)
            bytes.append(v)
            value >>= 7
        }
        
        let last = bytes.removeLast()
        bytes.append(last | 0x80)
        
        let data = Data(bytes)
        return data
    }
    
    private enum SequenceBits: UInt8 {
        case byte = 8
        case short = 16
        case long = 32
        case quad = 64
    }
    
    private func writeSequence(_ values: [Int]) -> Data {
        let type : UInt8 = 1
        let min = values.min()!
        let max = values.max()!
        let bits: SequenceBits
        if max < 256 {
            bits = .byte
        } else if max < 65_536 {
            bits = .short
        } else if max < 4_294_967_296 {
            bits = .long
        } else {
            bits = .quad
        }

        var data = Data()
        data.append(type)
        let bitWidth = bits.rawValue
        data.append(bitWidth)
        data.append(vByte(values.count))
        data.append(data.crc8Data)
        
        var bitsData = Data()
        switch bits {
        case .byte:
            bitsData.append(contentsOf: values.map { UInt8($0) })
        case .short:
            for v in values {
                bitsData.append(UInt8(v & 0xFF))
                bitsData.append(UInt8((v >> 8) & 0xFF))
            }
        case .long:
            fatalError("TODO: unimplemented")
        case .quad:
            fatalError("TODO: unimplemented")
        }
        data.append(bitsData)
        print("bits data is \(bitsData.count) bytes in length")
        data.append(bitsData.crc32Data)
        return data
    }
    
    private func writeBlockOffsets(_ offsets: [Int]) -> Data {
        return writeSequence(offsets)
    }
    
    private func writeDictionaryPartition(dictionary: TermDict, position: DictPosition, ids: [Int]) -> Data {
        var ids = ids
        let stringCount = ids.count
        let type : UInt8 = 2
        let blockSize = 8
        var offsetValues = [Int]()
        var sum = 0
        var blocks = [Data]()
        while !ids.isEmpty {
            offsetValues.append(sum)
            let b = writeDictionaryBlock(blockSize: blockSize, dictionary: dictionary, position: position, ids: &ids)
            blocks.append(b)
            sum += b.count
        }
        
        let blocksData = blocks.reduce(Data()) { $0 + $1 }
        let bytesCount = blocksData.count
        var p = Data()
        p.append(type)
        p.append(vByte(stringCount))
        p.append(vByte(bytesCount))
        p.append(vByte(blockSize))

        let crc8 = p.crc8Data
        p.append(crc8)
        
        let offsets = writeBlockOffsets(offsetValues)
        
        let data = p + offsets + blocksData

        let crc32 = blocksData.crc32Data
        return data + crc32
    }
    
    private func writeDictionary(dictionary: TermDict, sharedIDs: [Int], subjectIDs: [Int], predicateIDs: [Int], objectIDs: [Int]) -> Data {
        let count = sharedIDs.count + subjectIDs.count + predicateIDs.count + objectIDs.count
        let props = ["elements": "\(count)"]
        let ci = writeControlInformation(.dictionary, format: "<http://purl.org/HDT/hdt#dictionaryFour>", properties: props)
        let so = writeDictionaryPartition(dictionary: dictionary, position: .so, ids: sharedIDs)
        let s = writeDictionaryPartition(dictionary: dictionary, position: .so, ids: subjectIDs)
        let p = writeDictionaryPartition(dictionary: dictionary, position: .p, ids: predicateIDs)
        let o = writeDictionaryPartition(dictionary: dictionary, position: .so, ids: objectIDs)
        return ci + so + s + p + o
    }
    
    private func writeBytes(_ bytes: ContiguousArray<Int8>, length: Int) -> Data {
        var data = Data()
        if length == bytes.count {
            bytes.withUnsafeBufferPointer { (buffer) in
                data.append(buffer)
            }
        } else {
            for b in bytes.prefix(length) {
                let u = UInt8(bitPattern: b)
                data.append(u)
            }
        }
        return data
    }
    
    private func writeHeader(content: String) -> Data {
        let length = content.utf8.count
        let props = ["length": "\(length)"]
        let ci = writeControlInformation(.header, format: "ntriples", properties: props)
        let b = writeBytes(content.utf8CString, length: length)
        return ci + b
    }
    
    private static let cookie = "$HDT".data(using: .utf8)!
    private func writeControlInformation(_ type: HDT.ControlInformation.ControlType, format: String, properties: [String: String]) -> Data {
        let cType = type.rawValue
        let values = properties.map { (k, v) -> String in "\(k)=\(v);" }
        let props = values.sorted().joined(separator: "")

        var ci = Data(HDTSerializer.cookie)
        ci.append(cType)
        ci.append(format.data(using: .utf8)!)
        ci.append(0x00)
        ci.append(props.data(using: .utf8)!)
        ci.append(0x00)
        let crc16 = ci.crc16Data
        ci.append(crc16)
        
        let data = ci
        return data
    }
}

extension Data {
    var crc8Data: Data {
        let length8 = self.count
        let crc8 = self.withUnsafeBytes { (p : UnsafePointer<CChar>) -> Data in
            let rp = UnsafeMutableRawPointer(mutating: p)
            let c = CRC8(rp, length: length8)
            var d = Data()
            d.append(c.crc8)
            return d
        }
        return crc8
    }
    
    var crc32Data: Data {
        let length32 = self.count
        let crc32 = self.withUnsafeBytes { (p : UnsafePointer<CChar>) -> Data in
            let rp = UnsafeMutableRawPointer(mutating: p)
            let c = CRC32(rp, length: length32)
            var crc32 = c.crc32
            let data = Data(buffer: UnsafeBufferPointer(start: &crc32, count: 1))
            return data
        }
        return crc32
    }
    
    var crc16Data: Data {
        let crc16 = self.crc16().withUnsafeBytes { (p : UnsafePointer<UInt16>) -> Data in
            var crc16 =  p.pointee.byteSwapped
            let data = Data(buffer: UnsafeBufferPointer(start: &crc16, count: 1))
            return data
        }
        return crc16
    }
}

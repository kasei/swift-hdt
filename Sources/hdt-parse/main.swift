import SPARQLSyntax
import Foundation
import Kineo
import HDT

extension TurtleSerializer {
    public func serializeOrdered<T: TextOutputStream, I: IteratorProtocol>(_ iter: I, to stream: inout T) throws where I.Element == Triple {
        var triples = [Triple]()
        let seq = IteratorSequence(iter)
        var last: Term? = nil
        for t in seq {
            if let l = last, l != t.subject {
                try serialize(triples, to: &stream, emitHeader: false)
                triples = []
            }
            last = t.subject
            triples.append(t)
        }
        try serialize(triples, to: &stream)
    }
}

#if os(macOS)
import os.log
import os.signpost
let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
#endif

let args = CommandLine.arguments.dropFirst()
var index = args.startIndex

var simplify = false
var useTurtle = false
var prefixes = [String:Term]()
while index != args.endIndex, args[index].hasPrefix("-") {
    let flag = args[index]
    index += 1
    switch flag {
    case "-s":
        simplify = true
    case "-n":
        let ns = args[index]
        let iri = args[index+1]
        index += 2
        prefixes[ns] = Term(iri: iri)
    case "-o":
        let format = args[index]
        index += 1
        switch format {
        case "turtle":
            useTurtle = true
        case "ntriples":
            useTurtle = false
        default:
            print("Unknown output format: \(format)")
            exit(1)
        }
    default:
        print("Unrecognized command line argument: \(flag)")
        exit(1)
    }
}

guard index != args.endIndex else {
    print("""
    Usage: \(CommandLine.arguments.first!) [-s] [-o FORMAT] [-n NAMESPACE IRI] FILENAME.hdt
    
    """)
    exit(1);
}

let filename = args[index]

struct StdoutOutputStream: TextOutputStream {
    public init() {}
    public func write(_ string: String) {
        print(string, terminator: "")
    }
}

var stdout = StdoutOutputStream()

do {
    let p = try HDTParser(filename: filename)
    #if os(macOS)
    os_signpost(.begin, log: log, name: "Parsing", "Begin")
    #endif
    let hdt = try p.parse()
    hdt.simplifyBlankNodeIdentifiers = simplify
    
    #if os(macOS)
    os_signpost(.end, log: log, name: "Parsing", "Finished")
    #endif

    #if os(macOS)
    os_signpost(.begin, log: log, name: "Enumerating Triples", "Begin")
    #endif

    let triples = try hdt.triples()
    
    #if os(macOS)
    os_signpost(.begin, log: log, name: "Serialization", "N-Triples Serialization")
    #endif
    
    if useTurtle {
        let ser = TurtleSerializer(prefixes: prefixes)
        ser.serializeHeader(to: &stdout)
        try ser.serializeOrdered(triples, to: &stdout)
    } else {
        let ser : RDFSerializer = NTriplesSerializer()
        try ser.serialize(triples, to: &stdout)
    }
    

    #if os(macOS)
    os_signpost(.end, log: log, name: "Serialization", "N-Triples Serialization")
    #endif
    #if os(macOS)
    os_signpost(.end, log: log, name: "Enumerating Triples", "Finished")
    #endif
} catch let error {
    print(error)
}

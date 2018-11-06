import SPARQLSyntax
import Foundation
import Kineo
import HDT

#if os(macOS)
import os.log
import os.signpost
let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
#endif

let filename = CommandLine.arguments.dropFirst().first!

struct StdoutOutputStream: TextOutputStream {
    public init() {}
    public func write(_ string: String) {
        print(string, terminator: "")
    }
}

var stdout = StdoutOutputStream()

do {
    let useTurtle = false
    let p = try HDTParser(filename: filename)
    #if os(macOS)
    os_signpost(.begin, log: log, name: "Parsing", "Begin")
    #endif
    let hdt = try p.parse()
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
    let ser : RDFSerializer = useTurtle ? TurtleSerializer() : NTriplesSerializer()
    try ser.serialize(triples, to: &stdout)
    #if os(macOS)
    os_signpost(.end, log: log, name: "Serialization", "N-Triples Serialization")
    #endif

//    var s = ""
//    try ser.serialize(triples, to: &s)

//    for (i, t) in triples.enumerated() {
//        if i % 25_000 == 0 {
//            os_signpost(.event, log: log, name: "Enumerating Triples", "%{public}d triples", i)
//        }
//
//        try ser.serialize([t], to: &stdout)
//    }

    #if os(macOS)
    os_signpost(.end, log: log, name: "Enumerating Triples", "Finished")
    #endif
} catch let error {
    print(error)
}

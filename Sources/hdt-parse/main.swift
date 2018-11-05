import SPARQLSyntax
import Foundation
import Kineo
import HDT
import os.signpost
import os.log
import os.signpost

let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
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
    os_signpost(.begin, log: log, name: "Parsing", "Begin")
    let hdt = try p.parse()
    os_signpost(.end, log: log, name: "Parsing", "Finished")

    os_signpost(.begin, log: log, name: "Enumerating Triples", "Begin")

    let triples = try hdt.triples()
    
    os_signpost(.begin, log: log, name: "Serialization", "N-Triples Serialization")
    let ser : RDFSerializer = useTurtle ? TurtleSerializer() : NTriplesSerializer()
    try ser.serialize(triples, to: &stdout)
    os_signpost(.end, log: log, name: "Serialization", "N-Triples Serialization")

//    var s = ""
//    try ser.serialize(triples, to: &s)

//    for (i, t) in triples.enumerated() {
//        if i % 25_000 == 0 {
//            os_signpost(.event, log: log, name: "Enumerating Triples", "%{public}d triples", i)
//        }
//
//        try ser.serialize([t], to: &stdout)
//    }

    os_signpost(.end, log: log, name: "Enumerating Triples", "Finished")
} catch let error {
    print(error)
}

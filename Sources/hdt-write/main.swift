import SPARQLSyntax
import Foundation
import Kineo
import HDT

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
    Usage: \(CommandLine.arguments.first!) FILENAME.hdt FILENAME.ttl
    
    """)
    exit(1);
}

let filename = args[index]
let hdtURL = URL(fileURLWithPath: filename)
let rdfFile = args[index.advanced(by: 1)]

do {
    var triples = [Triple]()
    let c = RDFSerializationConfiguration.shared.parserFor(filename: rdfFile)!
    _ = try c.parser.parseFile(rdfFile, mediaType: c.mediaType, base: nil) { (s, p, o) in
        let t = Triple(subject: s, predicate: p, object: o)
        triples.append(t)
    }

    let writer = HDTSerializer()
    let data = try writer.serialize(triples)
    try data.write(to: hdtURL)
} catch let error {
    print(error)
}

import SPARQLSyntax
import Kineo
import HDT
import os.signpost
import os.log

let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
let filename = CommandLine.arguments.dropFirst().first!

do {
    let p = try HDTParser(filename: filename)
    os_signpost(.begin, log: log, name: "Parsing", "Begin")
    let hdt = try p.parse()
    os_signpost(.end, log: log, name: "Parsing", "Finished")

    os_signpost(.begin, log: log, name: "Enumerating Triples", "Begin")
    let triples = try hdt.triples()
    for (i, t) in triples.enumerated() {
        if i % 10_000 == 0 {
            os_signpost(.event, log: log, name: "Enumerating Triples", "%{public}d triples", i)
        }
        print(t.subject)
    }
    os_signpost(.end, log: log, name: "Enumerating Triples", "Finished")
} catch let error {
    print(error)
}

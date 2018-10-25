import HDT
import os.signpost
import os.log

let log = OSLog(subsystem: "us.kasei.swift.hdt", category: .pointsOfInterest)
let filename = CommandLine.arguments.dropFirst().first!
let p = HDTParser()
do {
    os_signpost(.begin, log: log, name: "Parsing", "Begin")
    let hdt = try p.parse(filename)
    os_signpost(.end, log: log, name: "Parsing", "Finished")

    os_signpost(.begin, log: log, name: "Enumerating Triples", "Begin")
    let triples = try hdt.triples()
    for t in triples {
        print(t)
    }
    os_signpost(.end, log: log, name: "Enumerating Triples", "Finished")
} catch let error {
    print(error)
}

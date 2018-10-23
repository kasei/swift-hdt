import HDT

let filename = CommandLine.arguments.dropFirst().first!
let p = HDTParser()
do {
    let triples = try p.triples(from: filename)
    for t in triples {
        print(t)
    }
} catch let error {
    print(error)
}

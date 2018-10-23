import HDT

let filename = CommandLine.arguments.dropFirst().first!
let p = HDTParser()
do {
    let hdt = try p.parse(filename)
    let triples = try hdt.triples()
    for t in triples {
        print(t)
    }
} catch let error {
    print(error)
}

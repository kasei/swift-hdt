import SPARQLSyntax
import Foundation
import Kineo
import HDT

let filename = CommandLine.arguments.dropFirst().first!

do {
    let p = try HDTParser(filename: filename)
    let hdt = try p.parse()
    print(hdt)
} catch let error {
    print(error)
}

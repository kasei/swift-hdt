import Foundation

struct BitmapTriplesData {
    var bitmapY : BlockIterator<Int>
    var bitmapZ : BlockIterator<Int>
    var arrayY : AnySequence<Int64>
    var arrayZ : AnySequence<Int64>
}


public enum TripleOrdering: Int, CustomStringConvertible {
    case unknown = 0
    case spo = 1
    case sop = 2
    case pso = 3
    case pos = 4
    case osp = 5
    case ops = 6
    
    public var description : String {
        let ordering = ["SPO", "SOP", "PSO", "POS", "OSP", "OPS"]
        return ordering[rawValue]
    }
}

struct TriplesMetadata {
    enum Format {
        case bitmap
        case list
    }
    
    var format: Format
    var ordering: TripleOrdering
    var count: Int?
    var offset: off_t
}

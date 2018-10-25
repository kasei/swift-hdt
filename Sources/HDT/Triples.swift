import Foundation

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
    var offset: off_t
}

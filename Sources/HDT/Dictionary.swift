import Foundation
import SPARQLSyntax

public struct HDTDictionary {
    public enum LookupPosition {
        case subject
        case predicate
        case object
    }
    
    var shared: [Int64: Term]
    var subjects: [Int64: Term]
    var predicates: [Int64: Term]
    var objects: [Int64: Term]
    
    public var count: Int {
        return shared.count + subjects.count + predicates.count + objects.count
    }
    
    public func term(for id: Int64, position: LookupPosition) -> Term? {
        if case .predicate = position {
            return predicates[id]
        } else {
            if let t = shared[id] {
                return t
            } else if let t = subjects[id] {
                return t
            } else {
                return objects[id]
            }
        }
    }
}

struct DictionaryMetadata {
    enum DictionaryType {
        case fourPart
    }
    
    var type: DictionaryType
    var offset: off_t
    var sharedOffset: off_t
    var subjectsOffset: off_t
    var predicatesOffset: off_t
    var objectsOffset: off_t
}

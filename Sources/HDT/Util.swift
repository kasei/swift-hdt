import Foundation

extension Data {
    public func getField(_ index: Int, width bitsField: Int) -> Int64 {
        let type = UInt32.self
        let bitWidth = type.bitWidth
        let bitPos = index * bitsField
        let i = bitPos / bitWidth
        let j = bitPos % bitWidth
        if (j+bitsField) <= bitWidth {
            let d : UInt32 = self.withUnsafeBytes { $0[i] }
            return (Int64(d) << (bitWidth-j-bitsField)) >> (bitWidth-bitsField)
        } else {
            return self.withUnsafeBytes { (p : UnsafePointer<UInt32>) -> Int64 in
                let _r = p[i]
                let _d = p[i+1]
                let r = Int64(_r) >> j
                let d = Int64(_d) << ((bitWidth<<1) - j - bitsField)
                return r | (d >> (bitWidth-bitsField))
            }
        }
    }

    public func getFieldsImmediate(width valueWidth: Int, count: Int) -> [Int64] {
        let bitWidth64 = UInt64.self.bitWidth

        var values = [Int64](reserveCapacity: count)
        var index = 0
        let baseMask64 = ((UInt64(1) << (valueWidth)) - 1)
        let splitShiftLeftBase = (bitWidth64<<1) - valueWidth
        let splitShiftRight = bitWidth64-valueWidth
        repeat {
            let bitPos = index * valueWidth
            index += 1
            
            let (offset_u64, intraValueBitOffset64) = bitPos.quotientAndRemainder(dividingBy: bitWidth64)
            if (intraValueBitOffset64+valueWidth) <= bitWidth64 {
                let d : UInt64 = self.withUnsafeBytes { $0[offset_u64] }
                let mask = baseMask64 << intraValueBitOffset64
                let v1 = (d & mask) >> intraValueBitOffset64
                values.append(Int64(v1))
            } else {
                let v1 = self.withUnsafeBytes { (p : UnsafePointer<UInt64>) -> Int64 in
                    let r = p[offset_u64] >> intraValueBitOffset64
                    let d = p[offset_u64+1] << (splitShiftLeftBase - intraValueBitOffset64)
                    let v = r | (d >> splitShiftRight)
                    return Int64(v)
                }
                values.append(Int64(v1))
            }
        } while index < count
        return values
    }
    
    public func getFields(width valueWidth: Int, count: Int) -> AnySequence<Int64> {
        let bitWidth64 = UInt64.self.bitWidth

        return AnySequence { () -> BlockIterator<Int64> in
            var index = 0
            let baseMask64 = ((UInt64(1) << (valueWidth)) - 1)
            let splitShiftLeftBase = (bitWidth64<<1) - valueWidth
            let splitShiftRight = bitWidth64-valueWidth
            return BlockIterator {
                guard index < count else {
                    return nil
                }
                let bitPos = index * valueWidth
                index += 1
                
                let (offset_u64, intraValueBitOffset64) = bitPos.quotientAndRemainder(dividingBy: bitWidth64)
                if (intraValueBitOffset64+valueWidth) <= bitWidth64 {
                    let d : UInt64 = self.withUnsafeBytes { $0[offset_u64] }
                    let mask = baseMask64 << intraValueBitOffset64
                    let v1 = (d & mask) >> intraValueBitOffset64
                    return [Int64(v1)]
                } else {
                    let v1 = self.withUnsafeBytes { (p : UnsafePointer<UInt64>) -> Int64 in
                        let r = p[offset_u64] >> intraValueBitOffset64
                        let d = p[offset_u64+1] << (splitShiftLeftBase - intraValueBitOffset64)
                        let v = r | (d >> splitShiftRight)
                        return Int64(v)
                    }
                    return [v1]
                }
            }
        }
    }
}


struct StderrOutputStream: TextOutputStream {
    public static let stream = StderrOutputStream()
    public func write(_ string: String) {fputs(string, stderr)}
}
var errStream = StderrOutputStream.stream
func warn(_ item: Any) {
    if true {
        print(item, to: &errStream)
    }
}

public enum FileState {
    case none
    case opened(CInt)
}

func readVByte(_ ptr : inout UnsafeMutableRawPointer) -> UInt {
    var p = ptr.assumingMemoryBound(to: UInt8.self)
    var value : UInt = 0
    var cont = true
    var shift = 0
    repeat {
        let b = p[0]
        let bvalue = UInt(b & 0x7f)
        cont = ((b & 0x80) == 0)
        p += 1
        value += bvalue << shift;
        shift += 7
    } while cont
    ptr = UnsafeMutableRawPointer(p)
    return value
}

func readData(from mmappedPtr: UnsafeMutableRawPointer, at offset: off_t, length: Int) throws -> Data {
    var readBuffer = mmappedPtr
    readBuffer += Int(offset)
    let data = Data(bytesNoCopy: readBuffer, count: length, deallocator: .none)
    return data
}

func readSequenceLazy(from mmappedPtr: UnsafeMutableRawPointer, at offset: off_t, assertType: UInt8? = nil) throws -> (AnySequence<Int64>, Int64) {
    var readBuffer = mmappedPtr
    readBuffer += Int(offset)
    
    let p = readBuffer.assumingMemoryBound(to: UInt8.self)
    let typeLength: Int
    if let assertType = assertType {
        let type = p[0]
        typeLength = 1
        guard type == assertType else {
            throw HDTError.error("Invalid dictionary LogSequence2 type (\(type)) at offset \(offset)")
        }
    } else {
        typeLength = 0
    }
    
    let bits = Int(p[typeLength])
    let bitsLength = 1
    
    var ptr = readBuffer + typeLength + bitsLength
    let entriesCount = Int(readVByte(&ptr))
    
//    let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
    // TODO: verify crc
    ptr += 1
    
    let arraySize = (bits * entriesCount + 7) / 8
    let sequenceDataOffset = off_t(readBuffer.distance(to: ptr))
    
    let sequenceData = try readData(from: mmappedPtr, at: offset + sequenceDataOffset, length: arraySize)
    ptr += arraySize
    
    let values = sequenceData.getFields(width: bits, count: entriesCount)
//    let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
    // TODO: verify crc
    ptr += 4
    
    let length = Int64(readBuffer.distance(to: ptr))
    
    let seq = AnySequence(values)
    return (seq, length)
}

func readSequenceImmediate(from mmappedPtr: UnsafeMutableRawPointer, at offset: off_t, assertType: UInt8? = nil) throws -> ([Int64], Int64) {
    var readBuffer = mmappedPtr
    readBuffer += Int(offset)
    
    let p = readBuffer.assumingMemoryBound(to: UInt8.self)
    let typeLength: Int
    if let assertType = assertType {
        let type = p[0]
        typeLength = 1
        guard type == assertType else {
            throw HDTError.error("Invalid dictionary LogSequence2 type (\(type)) at offset \(offset)")
        }
    } else {
        typeLength = 0
    }
    
    let bits = Int(p[typeLength])
    let bitsLength = 1
    
    var ptr = readBuffer + typeLength + bitsLength
    let entriesCount = Int(readVByte(&ptr))
    
//    let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
    // TODO: verify crc
    ptr += 1
    
    let arraySize = (bits * entriesCount + 7) / 8
    let sequenceDataOffset = off_t(readBuffer.distance(to: ptr))
    
    let sequenceData = try readData(from: mmappedPtr, at: offset + sequenceDataOffset, length: arraySize)
    ptr += arraySize
    
    let values = sequenceData.getFieldsImmediate(width: bits, count: entriesCount)
//    let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
    // TODO: verify crc
    ptr += 4
    
    let length = Int64(readBuffer.distance(to: ptr))
    
    return (values, length)
}

func readBitmap(from mmappedPtr: UnsafeMutableRawPointer, at offset: off_t) throws -> (BlockIterator<Int>, Int64, Int64) {
    var readBuffer = mmappedPtr
    readBuffer += Int(offset)

    let p = readBuffer.assumingMemoryBound(to: UInt8.self)
    let type = p[0]
    let typeLength = 1
    guard type == 1 else {
        throw HDTError.error("Invalid bitmap type (\(type)) at offset \(offset)")
    }
    
    var ptr = readBuffer + typeLength
    let bitCount = Int(readVByte(&ptr))
    let bytes = (bitCount + 7)/8
    
//    let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
    // TODO: verify crc
    ptr += 1
    
    let data = Data(bytesNoCopy: ptr, count: bytes, deallocator: .none)
//    let data = Data(bytes: ptr, count: bytes)

    var shift = 0
    let blockIterator = BlockIterator { () -> [Int]? in
        var block = [Int]()
        repeat {
            for _ in 0..<16 {
                guard shift < data.count else {
                    if block.isEmpty {
                        return nil
                    } else {
                        return block
                    }
                }
                let b = data[shift]
                let add = shift*8
                if (b & 0x01) > 0 { block.append(0 + add) }
                if (b & 0x02) > 0 { block.append(1 + add) }
                if (b & 0x04) > 0 { block.append(2 + add) }
                if (b & 0x08) > 0 { block.append(3 + add) }
                if (b & 0x10) > 0 { block.append(4 + add) }
                if (b & 0x20) > 0 { block.append(5 + add) }
                if (b & 0x40) > 0 { block.append(6 + add) }
                if (b & 0x80) > 0 { block.append(7 + add) }
    //            print("\(offset): [\(shift)]: \(block)")
                shift += 1
            }
        } while block.isEmpty
        return block
    }
    
    ptr += bytes
    
//    let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
    // TODO: verify crc
    ptr += 4
    
    let length = Int64(readBuffer.distance(to: ptr))
    
    return (blockIterator, Int64(bitCount), length)
}

func readArray(from mmappedPtr: UnsafeMutableRawPointer, at offset: off_t) throws -> (AnySequence<Int64>, Int64) {
    var readBuffer = mmappedPtr
    readBuffer += Int(offset)

    let p = readBuffer.assumingMemoryBound(to: UInt8.self)
    let type = p[0]
    
    switch type {
    case 1:
        let (blocks, blocksLength) = try readSequenceLazy(from: mmappedPtr, at: offset, assertType: 1)
        return (blocks, blocksLength)
    case 2:
        fatalError("TODO: Array read unimplemented: uint32")
    case 3:
        fatalError("TODO: Array read unimplemented: uint64")
    default:
        throw HDTError.error("Invalid array type (\(type)) at offset \(offset)")
    }
}

public struct ConcatenateIterator<I: IteratorProtocol> : IteratorProtocol {
    public typealias Element = I.Element
    var iterators: [I]
    var current: I?
    
    public init(_ iterators: I...) {
        self.iterators = iterators
        if let first = self.iterators.first {
            self.current = first
            self.iterators.remove(at: 0)
        } else {
            self.current = nil
        }
    }
    
    public mutating func next() -> I.Element? {
        repeat {
            guard current != nil else {
                return nil
            }
            if let item = current!.next() {
                return item
            } else if let i = iterators.first {
                current = i
                iterators.remove(at: 0)
            } else {
                current = nil
            }
        } while true
    }
}

public struct BlockIterator<K>: IteratorProtocol {
    var base: () -> [K]?
    var open: Bool
    var buffer: [K]
    var index: Int
    public init(_ base: @escaping () -> [K]?) {
        self.open = true
        self.base = base
        self.buffer = []
        self.index = buffer.endIndex
    }

    public mutating func dropFirst(_ k: Int) {
        // OPTIMIZE: drop in blocks
        for _ in 0..<k {
            _ = next()
        }
    }
    
    public mutating func next() -> K? {
        guard self.open else {
            return nil
        }
        
        repeat {
            if index != buffer.endIndex {
                let item = buffer[index]
                index = buffer.index(after: index)
                return item
            }

            guard open, let newBuffer = base() else {
                open = false
                return nil
            }

            buffer = newBuffer
            index = buffer.startIndex
        } while true
    }

}

struct PeekableIterator<T: IteratorProtocol> : IteratorProtocol {
    public typealias Element = T.Element
    private var generator: T
    private var bufferedElement: Element?
    public  init(generator: T) {
        self.generator = generator
        bufferedElement = self.generator.next()
    }
    
    public mutating func next() -> Element? {
        let r = bufferedElement
        bufferedElement = generator.next()
        return r
    }
    
    public func peek() -> Element? {
        return bufferedElement
    }
    
    mutating func dropWhile(filter: (Element) -> Bool) {
        while bufferedElement != nil {
            if !filter(bufferedElement!) {
                break
            }
            _ = next()
        }
    }
    
    mutating public func elements() -> [Element] {
        var elements = [Element]()
        while let e = next() {
            elements.append(e)
        }
        return elements
    }
}

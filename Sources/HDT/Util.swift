import Foundation

extension Data {
    public func getField(_ index: Int, width bitsField: Int) -> Int {
        let type = UInt32.self
        let W = type.bitWidth
        let bitPos = index * bitsField
        let i = bitPos / W
        let j = bitPos % W
        if (j+bitsField) <= W {
            let d : UInt32 = self.withUnsafeBytes { $0[i] }
            return Int((d << (W-j-bitsField)) >> (W-bitsField))
        } else {
            let _r : UInt32 = self.withUnsafeBytes { $0[i] }
            let _d : UInt32 = self.withUnsafeBytes { $0[i+1] }
            let r = Int(_r >> j)
            let d = Int(_d << ((W<<1) - j - bitsField))
            return r | (d >> (W-bitsField))
        }
    }
}


struct StderrOutputStream: TextOutputStream {
    public static let stream = StderrOutputStream()
    public func write(_ string: String) {fputs(string, stderr)}
}
var errStream = StderrOutputStream.stream
public func warn(_ item: Any) {
    if false {
        print(item, to: &errStream)
    }
}

public enum FileState {
    case none
    case opened(CInt)
}

public protocol FileBased {
    var state: FileState { get set }
}

extension FileBased {
    func readData(at offset: off_t, length: Int) throws -> Data {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        var size = 1024
        while size < length {
            size *= 2
        }
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r >= length else { throw HDTError.error("Not enough bytes read for data at offset \(offset)") }
        let data = Data(bytes: readBuffer, count: length)
        return data
    }
    
    func readBitmap(at offset: off_t) throws -> (IndexSet, Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 2000 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = p[0]
        let typeLength = 1
        guard type == 1 else {
            throw HDTError.error("Invalid bitmap type (\(type)) at offset \(offset)")
        }
        
        var ptr = readBuffer + typeLength
        let bitCount = Int(readVByte(&ptr))
        let bytes = (bitCount + 7)/8
        print("reading bitmap data: \(bytes) bytes")
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        // TODO: verify crc
        ptr += 1
        
        let data = Data(bytes: ptr, count: bytes)
        var i = IndexSet()
        for (shift, b) in data.enumerated() {
            let add = shift*8
            if (b & 0x01) > 0 { i.insert(0 + add) }
            if (b & 0x02) > 0 { i.insert(1 + add) }
            if (b & 0x04) > 0 { i.insert(2 + add) }
            if (b & 0x08) > 0 { i.insert(3 + add) }
            if (b & 0x10) > 0 { i.insert(4 + add) }
            if (b & 0x20) > 0 { i.insert(5 + add) }
            if (b & 0x40) > 0 { i.insert(6 + add) }
            if (b & 0x80) > 0 { i.insert(7 + add) }
        }
        ptr += bytes
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        ptr += 4
        
        let length = Int64(readBuffer.distance(to: ptr))
        return (i, length)
    }
    
    func readArray(at offset: off_t) throws -> ([Int64], Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 1024 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        let r = pread(fd, readBuffer, size, offset)
        guard r > 0 else { throw HDTError.error("Not enough bytes read for HDT triples") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let type = p[0]
        
        switch type {
        case 1:
            let (blocks, blocksLength) = try readSequence(at: offset, assertType: 1)
            let array = blocks.map { Int64($0) }
            warn("array prefix: \(array.prefix(32))")
            return (array, blocksLength)
        case 2:
            fatalError("TODO: Array read unimplemented: uint32")
        case 3:
            fatalError("TODO: Array read unimplemented: uint64")
        default:
            throw HDTError.error("Invalid array type (\(type)) at offset \(offset)")
        }
    }
    
    func readSequence(at offset: off_t, assertType: UInt8? = nil) throws -> (AnySequence<Int>, Int64) {
        guard case .opened(let fd) = state else {
            throw HDTError.error("HDT file not opened")
        }
        let size = 64 * 1024 * 1024 // TODO: this shouldn't be hard-coded
        var readBuffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 0)
        defer { readBuffer.deallocate() }
        var r = pread(fd, readBuffer, size, offset)
        guard r > 4 else { throw HDTError.error("Not enough bytes read for HDT dictionary sequence") }
        
        let p = readBuffer.assumingMemoryBound(to: UInt8.self)
        let typeLength: Int
        if let assertType = assertType {
            let type = p[0]
            typeLength = 1
            guard type == assertType else {
                throw HDTError.error("Invalid dictionary LogSequence2 type (\(type)) at offset \(offset)")
            }
            warn("Sequence type: \(type)")
        } else {
            typeLength = 0
        }
        
        let bits = Int(p[typeLength])
        let bitsLength = 1
        warn("Sequence bits: \(bits)")
        
        var ptr = readBuffer + typeLength + bitsLength
        let entriesCount = Int(readVByte(&ptr))
        warn("Sequence entries: \(entriesCount)")
        
        let crc8 = ptr.assumingMemoryBound(to: UInt8.self).pointee
        // TODO: verify crc
        ptr += 1
        
        let arraySize = (bits * entriesCount + 7) / 8
        warn("Array size for log sequence: \(arraySize)")
        let sequenceDataOffset = Int64(readBuffer.distance(to: ptr))
        warn("Offset for log sequence: \(sequenceDataOffset)")
        
        let sequenceData = try readData(at: offset + sequenceDataOffset, length: arraySize)
        ptr += arraySize
        
        var values = [Int](reserveCapacity: entriesCount)
        for i in 0..<entriesCount {
            let value = sequenceData.getField(i, width: bits)
            values.append(value)
        }
        
        let crc32 = UInt32(bigEndian: ptr.assumingMemoryBound(to: UInt32.self).pointee)
        // TODO: verify crc
        ptr += 4
        
        let length = Int64(readBuffer.distance(to: ptr))
        
        let seq = AnySequence(values)
        return (seq, length)
    }
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
        //            warn("vbyte: \(String(format: "0x%02x", b)), byte value=\(bvalue), continue=\(cont)")
        p += 1
        value += bvalue << shift;
        shift += 7
    } while cont
    let bytes = ptr.distance(to: p)
    //        warn("read \(bytes) bytes to produce value \(value)")
    ptr = UnsafeMutableRawPointer(p)
    return value
}

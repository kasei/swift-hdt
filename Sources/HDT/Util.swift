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

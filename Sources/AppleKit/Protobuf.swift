import Foundation
import CZlib

/// Inflates gzip data (magic 1F 8B). Returns nil for anything else.
public func gunzip(_ data: Data) -> Data? {
    guard data.count > 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
    var stream = z_stream()
    guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var out = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var input = [UInt8](data)
    let ok: Bool = input.withUnsafeMutableBufferPointer { inBuf in
        stream.next_in = inBuf.baseAddress
        stream.avail_in = uInt(inBuf.count)
        while true {
            let rc: Int32 = chunk.withUnsafeMutableBufferPointer { outBuf in
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            out.append(contentsOf: chunk[0..<(chunk.count - Int(stream.avail_out))])
            if rc == Z_STREAM_END { return true }
            if rc != Z_OK { return false }
        }
    }
    return ok ? out : nil
}

/// One decoded protobuf field. Wire type 0 fills `varint`, wire type 2 fills `bytes`.
public struct PBField {
    public let number: Int
    public let wire: Int
    public let varint: UInt64
    public let bytes: Data

    public var message: [PBField] { (try? PB.parse(bytes)) ?? [] }
    /// The varint as Int, clamped so hostile values cannot trap.
    public var int: Int { Int(clamping: varint) }
    public var string: String { String(decoding: bytes, as: UTF8.self) }
}

/// A schema-less protobuf reader. Apple ships no .proto for these blobs,
/// so callers address fields by number.
public enum PB {
    public static func parse(_ data: Data) throws -> [PBField] {
        let b = [UInt8](data)
        var i = 0
        var out: [PBField] = []
        func varint() throws -> UInt64 {
            var r: UInt64 = 0, s: UInt64 = 0
            while true {
                guard i < b.count, s < 64 else { throw AppleError.invalid("truncated protobuf") }
                let x = b[i]; i += 1
                r |= UInt64(x & 0x7F) << s; s += 7
                if x < 0x80 { return r }
            }
        }
        while i < b.count {
            let key = try varint()
            let num = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: out.append(PBField(number: num, wire: 0, varint: try varint(), bytes: Data()))
            case 1:
                guard i + 8 <= b.count else { throw AppleError.invalid("truncated protobuf") }
                out.append(PBField(number: num, wire: 1, varint: 0, bytes: Data(b[i..<i+8]))); i += 8
            case 2:
                guard let n = Int(exactly: try varint()), n <= b.count - i else { throw AppleError.invalid("truncated protobuf") }
                out.append(PBField(number: num, wire: 2, varint: 0, bytes: Data(b[i..<i+n]))); i += n
            case 5:
                guard i + 4 <= b.count else { throw AppleError.invalid("truncated protobuf") }
                out.append(PBField(number: num, wire: 5, varint: 0, bytes: Data(b[i..<i+4]))); i += 4
            default: throw AppleError.invalid("protobuf wire type \(wire)")
            }
        }
        return out
    }
}

extension Array where Element == PBField {
    public func first(_ n: Int) -> PBField? { first { $0.number == n } }
    public func all(_ n: Int) -> [PBField] { filter { $0.number == n } }
    /// Follows a path of field numbers, taking the first match at each level.
    public func path(_ ns: Int...) -> PBField? {
        var cur: [PBField] = self
        var hit: PBField?
        for n in ns {
            guard let f = cur.first(n) else { return nil }
            hit = f
            cur = f.message
        }
        return hit
    }
}

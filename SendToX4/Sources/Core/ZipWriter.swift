import Foundation
import Compression

/// Minimal ZIP writer that supports STORED (no compression) and DEFLATE entries.
/// Just enough for EPUB output: stable, no external deps, single file.
public final class ZipWriter {
    public enum Method {
        case stored
        case deflate
    }

    public struct Entry {
        public var path: String
        public var data: Data
        public var method: Method
        public init(path: String, data: Data, method: Method) {
            self.path = path
            self.data = data
            self.method = method
        }
    }

    private struct EntryRecord {
        let path: String
        let method: Method
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    public init() {}

    public func write(entries: [Entry]) throws -> Data {
        var out = Data()
        var records: [EntryRecord] = []
        let (dosTime, dosDate) = Self.dosTimestamp(for: Date())

        for entry in entries {
            let pathBytes = Data(entry.path.utf8)
            let crc = Self.crc32(entry.data)
            let uncompressed = UInt32(entry.data.count)

            let payload: Data
            let methodCode: UInt16
            switch entry.method {
            case .stored:
                payload = entry.data
                methodCode = 0
            case .deflate:
                payload = try Self.deflate(entry.data)
                methodCode = 8
            }
            let compressed = UInt32(payload.count)
            let offset = UInt32(out.count)

            // Local file header
            var lfh = Data()
            lfh.appendLE(UInt32(0x04034b50))     // signature
            lfh.appendLE(UInt16(20))             // version needed
            lfh.appendLE(UInt16(0))              // flags
            lfh.appendLE(methodCode)
            lfh.appendLE(dosTime)
            lfh.appendLE(dosDate)
            lfh.appendLE(crc)
            lfh.appendLE(compressed)
            lfh.appendLE(uncompressed)
            lfh.appendLE(UInt16(pathBytes.count))
            lfh.appendLE(UInt16(0))              // extra length
            out.append(lfh)
            out.append(pathBytes)
            out.append(payload)

            records.append(EntryRecord(
                path: entry.path,
                method: entry.method,
                crc32: crc,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: offset,
                dosTime: dosTime,
                dosDate: dosDate
            ))
        }

        // Central directory
        let cdStart = UInt32(out.count)
        for r in records {
            let pathBytes = Data(r.path.utf8)
            var cdh = Data()
            cdh.appendLE(UInt32(0x02014b50))     // signature
            cdh.appendLE(UInt16(20))             // version made by
            cdh.appendLE(UInt16(20))             // version needed
            cdh.appendLE(UInt16(0))              // flags
            cdh.appendLE(UInt16(r.method == .stored ? 0 : 8))
            cdh.appendLE(r.dosTime)
            cdh.appendLE(r.dosDate)
            cdh.appendLE(r.crc32)
            cdh.appendLE(r.compressedSize)
            cdh.appendLE(r.uncompressedSize)
            cdh.appendLE(UInt16(pathBytes.count))
            cdh.appendLE(UInt16(0))              // extra length
            cdh.appendLE(UInt16(0))              // comment length
            cdh.appendLE(UInt16(0))              // disk number
            cdh.appendLE(UInt16(0))              // internal attrs
            cdh.appendLE(UInt32(0))              // external attrs
            cdh.appendLE(r.localHeaderOffset)
            out.append(cdh)
            out.append(pathBytes)
        }
        let cdSize = UInt32(out.count) - cdStart

        // End of central directory record
        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))
        eocd.appendLE(UInt16(0))                 // disk
        eocd.appendLE(UInt16(0))                 // disk with cd
        eocd.appendLE(UInt16(records.count))     // entries on this disk
        eocd.appendLE(UInt16(records.count))     // total entries
        eocd.appendLE(cdSize)
        eocd.appendLE(cdStart)
        eocd.appendLE(UInt16(0))                 // comment length
        out.append(eocd)
        return out
    }

    // MARK: - Helpers

    private static func dosTimestamp(for date: Date) -> (UInt16, UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, comps.year ?? 1980)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let yearPart: UInt16 = UInt16((year - 1980) & 0x7f)
        let monthPart: UInt16 = UInt16(month & 0x0f)
        let dayPart: UInt16 = UInt16(day & 0x1f)
        let dosDate: UInt16 = (yearPart << 9) | (monthPart << 5) | dayPart
        let hourPart: UInt16 = UInt16(hour & 0x1f)
        let minutePart: UInt16 = UInt16(minute & 0x3f)
        let secondPart: UInt16 = UInt16((second / 2) & 0x1f)
        let dosTime: UInt16 = (hourPart << 11) | (minutePart << 5) | secondPart
        return (dosTime, dosDate)
    }

    /// Raw DEFLATE (RFC 1951), as required by ZIP method 8.
    private static func deflate(_ source: Data) throws -> Data {
        if source.isEmpty { return Data() }
        // compression_encode_buffer with COMPRESSION_ZLIB is RAW deflate (no zlib header).
        let dstCapacity = max(source.count * 2 + 64, 1024)
        var dst = Data(count: dstCapacity)
        let written = source.withUnsafeBytes { srcRaw -> Int in
            let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress!
            return dst.withUnsafeMutableBytes { dstRaw -> Int in
                let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                return compression_encode_buffer(dstPtr, dstCapacity, srcPtr, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        if written == 0 {
            throw NSError(domain: "ZipWriter", code: -1, userInfo: [NSLocalizedDescriptionKey: "deflate failed"])
        }
        dst.count = written
        return dst
    }

    // CRC-32/ISO-HDLC, polynomial 0xedb88320, the variant used in ZIP.
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xedb88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for b in bytes {
                c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8)
            }
        }
        return c ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

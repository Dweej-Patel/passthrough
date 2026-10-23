import CZlib
import Foundation

/// One zlib stream that lasts the whole connection, as RFB's Zlib and ZRLE
/// encodings use: each rectangle's compressed bytes continue it and end on
/// a sync flush, so they inflate completely on their own.
final class Inflater {
    enum Failure: Error { case corrupt }

    private var stream = z_stream()
    private var ready = false

    init() {
        ready = cz_inflate_init(&stream) == Z_OK
    }

    deinit {
        if ready { inflateEnd(&stream) }
    }

    /// Everything `input` inflates to.
    func inflated(_ input: Data) throws -> Data {
        guard ready else { throw Failure.corrupt }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(source.count)
            repeat {
                let produced = try chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    let status = inflate(&stream, Z_SYNC_FLUSH)
                    guard status == Z_OK || status == Z_BUF_ERROR || status == Z_STREAM_END else { throw Failure.corrupt }
                    return buffer.count - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
                if produced == 0 { break }
            } while stream.avail_in > 0 || stream.avail_out == 0
        }
        stream.next_in = nil
        stream.avail_in = 0
        return output
    }
}

/// The other end, for tests and fake servers: one stream, sync-flushed per call.
final class Deflater {
    private var stream = z_stream()
    private var ready = false

    init(level: Int32 = 6) {
        ready = cz_deflate_init(&stream, level) == Z_OK
    }

    deinit {
        if ready { deflateEnd(&stream) }
    }

    func deflated(_ input: Data) -> Data {
        guard ready else { return Data() }
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(source.count)
            repeat {
                let produced = chunk.withUnsafeMutableBufferPointer { buffer -> Int in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    _ = deflate(&stream, Z_SYNC_FLUSH)
                    return buffer.count - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk[0..<produced])
            } while stream.avail_out == 0
        }
        stream.next_in = nil
        stream.avail_in = 0
        return output
    }
}

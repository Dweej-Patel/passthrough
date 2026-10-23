import CoreGraphics
import Foundation

/// The Mac's screen as last drawn: 32-bit pixels, 0x00RRGGBB in memory order
/// B, G, R, x (the pixel format `RFBClient` asks for), which CoreGraphics
/// reads as little-endian "skip first" without converting.
final class Framebuffer {
    enum Failure: Error { case outOfBounds, corrupt }

    private(set) var width: Int
    private(set) var height: Int
    private var pixels: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0, count: width * height)
    }

    func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt32](repeating: 0, count: width * height)
    }

    func pixel(x: Int, y: Int) -> UInt32 { pixels[y * width + x] }

    private func check(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        guard x >= 0, y >= 0, w >= 0, h >= 0, x + w <= width, y + h <= height else { throw Failure.outOfBounds }
    }

    /// Raw encoding: `w`·`h` pixels, 4 bytes each, row by row.
    func raw(x: Int, y: Int, w: Int, h: Int, _ data: UnsafeRawBufferPointer) throws {
        try check(x, y, w, h)
        guard data.count >= w * h * 4 else { throw Failure.corrupt }
        let width = self.width
        pixels.withUnsafeMutableBytes { target in
            for row in 0..<h {
                let to = target.baseAddress! + ((y + row) * width + x) * 4
                to.copyMemory(from: data.baseAddress! + row * w * 4, byteCount: w * 4)
            }
        }
    }

    /// CopyRect: the rectangle at (`fromX`, `fromY`) moves to (`x`, `y`).
    func copy(fromX: Int, fromY: Int, x: Int, y: Int, w: Int, h: Int) throws {
        try check(x, y, w, h)
        try check(fromX, fromY, w, h)
        let width = self.width
        pixels.withUnsafeMutableBufferPointer { p in
            // Overlapping moves: copy rows in the order that doesn't overwrite what's still to read.
            let rows = fromY < y ? Array((0..<h).reversed()) : Array(0..<h)
            for row in rows {
                let from = p.baseAddress! + (fromY + row) * width + fromX
                let to = p.baseAddress! + (y + row) * width + x
                to.update(from: from, count: w)   // memmove semantics
            }
        }
    }

    /// ZRLE (RFC 6143 §7.7.6): 64×64 tiles of the inflated `data`, with
    /// 3-byte pixels (B, G, R). Written a row or a run at a time through
    /// pointers: this runs for every pixel of every update.
    func zrle(x: Int, y: Int, w: Int, h: Int, _ data: Data) throws {
        try check(x, y, w, h)
        guard w > 0, h > 0 else { return }
        let width = self.width
        let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: 127)
        defer { palette.deallocate() }
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let src = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw Failure.corrupt }
            let end = source.count
            var p = 0
            func cpixel(_ at: Int) -> UInt32 {
                UInt32(src[at]) | UInt32(src[at + 1]) << 8 | UInt32(src[at + 2]) << 16
            }
            func readPalette(_ size: Int) throws {
                guard p + 3 * size <= end else { throw Failure.corrupt }
                for i in 0..<size { palette[i] = cpixel(p + 3 * i) }
                p += 3 * size
            }
            func runLength() throws -> Int {
                var length = 1
                while true {
                    guard p < end else { throw Failure.corrupt }
                    let byte = Int(src[p]); p += 1
                    length += byte
                    if byte != 255 { return length }
                }
            }
            try pixels.withUnsafeMutableBufferPointer { out in
                let base = out.baseAddress!
                for ty in stride(from: 0, to: h, by: 64) {
                    let th = min(64, h - ty)
                    for tx in stride(from: 0, to: w, by: 64) {
                        let tw = min(64, w - tx)
                        let origin = base + (y + ty) * width + x + tx
                        // Runs fill the tile left to right, wrapping rows.
                        var row = 0, column = 0
                        func fill(_ value: UInt32, _ run: Int) throws {
                            var left = run
                            while left > 0 {
                                guard row < th else { throw Failure.corrupt }
                                let n = min(left, tw - column)
                                (origin + row * width + column).update(repeating: value, count: n)
                                column += n
                                left -= n
                                if column == tw { column = 0; row += 1 }
                            }
                        }
                        guard p < end else { throw Failure.corrupt }
                        let sub = Int(src[p]); p += 1
                        switch sub {
                        case 0:
                            guard p + 3 * tw * th <= end else { throw Failure.corrupt }
                            for r in 0..<th {
                                let line = origin + r * width
                                var q = p + 3 * tw * r
                                for c in 0..<tw {
                                    line[c] = UInt32(src[q]) | UInt32(src[q + 1]) << 8 | UInt32(src[q + 2]) << 16
                                    q += 3
                                }
                            }
                            p += 3 * tw * th
                        case 1:
                            try readPalette(1)
                            for r in 0..<th { (origin + r * width).update(repeating: palette[0], count: tw) }
                        case 2...16:
                            try readPalette(sub)
                            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
                            let rowBytes = (tw * bits + 7) / 8
                            guard p + rowBytes * th <= end else { throw Failure.corrupt }
                            let mask = (1 << bits) - 1
                            for r in 0..<th {
                                let line = origin + r * width
                                let rowStart = src + p + r * rowBytes
                                for c in 0..<tw {
                                    let bit = c * bits
                                    let index = Int(rowStart[bit >> 3]) >> (8 - bits - bit & 7) & mask
                                    guard index < sub else { throw Failure.corrupt }
                                    line[c] = palette[index]
                                }
                            }
                            p += rowBytes * th
                        case 128:
                            while row < th {
                                guard p + 3 <= end else { throw Failure.corrupt }
                                let value = cpixel(p); p += 3
                                try fill(value, try runLength())
                            }
                        case 130...255:
                            let size = sub - 128
                            try readPalette(size)
                            while row < th {
                                guard p < end else { throw Failure.corrupt }
                                let code = Int(src[p]); p += 1
                                guard code & 127 < size else { throw Failure.corrupt }
                                try fill(palette[code & 127], code & 128 != 0 ? try runLength() : 1)
                            }
                        default:
                            throw Failure.corrupt
                        }
                    }
                }
            }
        }
    }

    /// A snapshot for display (copied: drawing goes on meanwhile).
    func image() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

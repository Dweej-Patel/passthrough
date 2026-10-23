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
    /// 3-byte pixels (B, G, R).
    func zrle(x: Int, y: Int, w: Int, h: Int, _ data: Data) throws {
        try check(x, y, w, h)
        let width = self.width
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            let src = source.bindMemory(to: UInt8.self)
            var p = 0
            func need(_ count: Int) throws { if p + count > src.count { throw Failure.corrupt } }
            func cpixel() throws -> UInt32 {
                try need(3)
                defer { p += 3 }
                return UInt32(src[p]) | UInt32(src[p + 1]) << 8 | UInt32(src[p + 2]) << 16
            }
            func runLength() throws -> Int {
                var length = 1
                while true {
                    try need(1)
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
                        let count = tw * th
                        func put(_ index: Int, _ value: UInt32) {
                            base[(y + ty + index / tw) * width + x + tx + index % tw] = value
                        }
                        try need(1)
                        let sub = Int(src[p]); p += 1
                        switch sub {
                        case 0:
                            for index in 0..<count { put(index, try cpixel()) }
                        case 1:
                            let value = try cpixel()
                            for index in 0..<count { put(index, value) }
                        case 2...16:
                            let palette = try (0..<sub).map { _ in try cpixel() }
                            let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
                            let rowBytes = (tw * bits + 7) / 8
                            try need(rowBytes * th)
                            let mask = (1 << bits) - 1
                            for row in 0..<th {
                                let rowStart = p + row * rowBytes
                                for column in 0..<tw {
                                    let bit = column * bits
                                    let byte = Int(src[rowStart + bit / 8])
                                    let index = byte >> (8 - bits - bit % 8) & mask
                                    guard index < palette.count else { throw Failure.corrupt }
                                    put(row * tw + column, palette[index])
                                }
                            }
                            p += rowBytes * th
                        case 128:
                            var index = 0
                            while index < count {
                                let value = try cpixel()
                                let run = try runLength()
                                guard index + run <= count else { throw Failure.corrupt }
                                for i in index..<(index + run) { put(i, value) }
                                index += run
                            }
                        case 130...255:
                            let palette = try (0..<(sub - 128)).map { _ in try cpixel() }
                            var index = 0
                            while index < count {
                                try need(1)
                                let code = Int(src[p]); p += 1
                                guard code & 127 < palette.count else { throw Failure.corrupt }
                                let run = code & 128 != 0 ? try runLength() : 1
                                guard index + run <= count else { throw Failure.corrupt }
                                for i in index..<(index + run) { put(i, palette[code & 127]) }
                                index += run
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

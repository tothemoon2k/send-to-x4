import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Downloads, decodes, and prepares images for the X4's 4.3" 480×800 e-ink
/// panel. The CrossPoint renderer doesn't tone-map for us, so we do the work
/// here: convert to 8-bit grayscale, resize so the longer side is at most
/// 800px, then Atkinson-dither to a 16-level palette. The result looks like
/// classic Mac graphics — sharp, paper-like, no muddy mid-tones.
public enum ImageProcessor {

    public struct Output {
        public var pngData: Data
        public var width: Int
        public var height: Int
    }

    public enum Error: Swift.Error {
        case downloadFailed(URL, Int)
        case decodeFailed(URL)
        case encodeFailed
    }

    /// Hard caps tuned to the X4 panel.
    public static let maxWidth: Int = 480
    public static let maxHeight: Int = 800
    public static let levels: Int = 16

    public static func download(_ url: URL, timeout: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) SendToX4/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Error.downloadFailed(url, http.statusCode)
        }
        return data
    }

    /// Convert an arbitrary image into an X4-tuned PNG.
    public static func process(_ data: Data, sourceURL: URL? = nil) throws -> Output {
        #if canImport(CoreGraphics)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Error.decodeFailed(sourceURL ?? URL(fileURLWithPath: "/dev/null"))
        }

        let (targetW, targetH) = fittedSize(width: cg.width, height: cg.height,
                                            maxW: maxWidth, maxH: maxHeight)

        guard let grayContext = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW,                      // tightly packed gray
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { throw Error.encodeFailed }

        grayContext.interpolationQuality = .high
        // Composite onto white so transparent PNGs don't ghost.
        grayContext.setFillColor(CGColor(gray: 1, alpha: 1))
        grayContext.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        grayContext.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let dataPtr = grayContext.data else { throw Error.encodeFailed }
        let buffer = dataPtr.bindMemory(to: UInt8.self, capacity: targetW * targetH)
        atkinsonDither(buffer: buffer, width: targetW, height: targetH, levels: levels)

        guard let dithered = grayContext.makeImage() else { throw Error.encodeFailed }

        let mutableData = CFDataCreateMutable(nil, 0)!
        let typeId = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(mutableData, typeId, 1, nil) else {
            throw Error.encodeFailed
        }
        CGImageDestinationAddImage(dest, dithered, nil)
        guard CGImageDestinationFinalize(dest) else { throw Error.encodeFailed }

        return Output(pngData: mutableData as Data, width: targetW, height: targetH)
        #else
        throw Error.encodeFailed
        #endif
    }

    private static func fittedSize(width w: Int, height h: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        if w <= maxW && h <= maxH { return (w, h) }
        let scale = min(Double(maxW) / Double(w), Double(maxH) / Double(h))
        let nw = max(1, Int((Double(w) * scale).rounded()))
        let nh = max(1, Int((Double(h) * scale).rounded()))
        return (nw, nh)
    }

    /// Atkinson dithering. Diffuses 6/8 of the error to neighbors (slightly
    /// less than Floyd-Steinberg's 16/16), which preserves contrast and looks
    /// crisp on e-ink. Quantizes to evenly-spaced gray levels.
    static func atkinsonDither(buffer: UnsafeMutablePointer<UInt8>, width: Int, height: Int, levels: Int) {
        let step = 255.0 / Double(levels - 1)

        // Use a Float scratch buffer so we can carry fractional error without saturating.
        let count = width * height
        var work = [Float](repeating: 0, count: count)
        for i in 0..<count {
            work[i] = Float(buffer[i])
        }

        func at(_ x: Int, _ y: Int) -> Int? {
            if x < 0 || x >= width || y < 0 || y >= height { return nil }
            return y * width + x
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let old = work[idx]
                let q = (round(Double(old) / step) * step).clamped(0, 255)
                let new = Float(q)
                work[idx] = new
                let err = (old - new) / 8.0

                let neighbors: [(Int, Int)] = [
                    ( 1, 0), ( 2, 0),
                    (-1, 1), ( 0, 1), ( 1, 1),
                    ( 0, 2)
                ]
                for (dx, dy) in neighbors {
                    if let nIdx = at(x + dx, y + dy) {
                        work[nIdx] = (work[nIdx] + err).clamped(0, 255)
                    }
                }
            }
        }

        for i in 0..<count {
            let v = work[i].rounded()
            buffer[i] = UInt8(min(255, max(0, Int(v))))
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, self))
    }
}

private extension Float {
    func clamped(_ lo: Float, _ hi: Float) -> Float {
        Swift.min(hi, Swift.max(lo, self))
    }
}

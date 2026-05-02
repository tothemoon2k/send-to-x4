import Foundation
#if canImport(AppKit)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Generates a clean, e-ink-friendly cover PNG. Pure black/cream typography —
/// no gradients, no photographs (the X4 renderer doesn't tone-map for us, so
/// elaborate covers look muddy). Sized for the X4's 480×800 panel but doubled
/// for clarity in EPUB readers on bigger screens.
public enum CoverGenerator {
    public struct Input {
        public var title: String
        public var author: String?
        public var source: String?
        public init(title: String, author: String? = nil, source: String? = nil) {
            self.title = title
            self.author = author
            self.source = source
        }
    }

    public static func makePNG(_ input: Input) -> Data? {
        #if canImport(AppKit)
        let width: CGFloat = 600
        let height: CGFloat = 800

        // Slightly warm cream background — looks like book paper on e-ink.
        let bg = NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.88, alpha: 1)
        let ink = NSColor.black

        guard let context = CGContext(
            data: nil,
            width: Int(width),
            height: Int(height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Background
        bg.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

        // Inset frame (thin border + thicker inner border, library-edition feel)
        ink.setStroke()
        let outer = NSRect(x: 28, y: 28, width: width - 56, height: height - 56)
        let outerPath = NSBezierPath(rect: outer)
        outerPath.lineWidth = 1
        outerPath.stroke()
        let inner = NSRect(x: 36, y: 36, width: width - 72, height: height - 72)
        let innerPath = NSBezierPath(rect: inner)
        innerPath.lineWidth = 0.5
        innerPath.stroke()

        // Type
        let titleFont = NSFont(name: "Hoefler Text", size: 44)
            ?? NSFont(name: "Iowan Old Style", size: 44)
            ?? NSFont(name: "Charter", size: 44)
            ?? NSFont(name: "Georgia", size: 44)
            ?? NSFont.systemFont(ofSize: 44, weight: .semibold)

        let authorFont = NSFont(name: "Hoefler Text", size: 22)
            ?? NSFont(name: "Iowan Old Style Italic", size: 22)
            ?? NSFont(name: "Georgia-Italic", size: 22)
            ?? NSFont.systemFont(ofSize: 22, weight: .regular)

        let sourceFont = NSFont(name: "Hoefler Text", size: 13)
            ?? NSFont.systemFont(ofSize: 13, weight: .regular)

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineHeightMultiple = 1.0
        titleStyle.lineBreakMode = .byWordWrapping
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: ink,
            .paragraphStyle: titleStyle,
            .kern: 0.5
        ]

        let authorStyle = NSMutableParagraphStyle()
        authorStyle.alignment = .center
        let authorAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(authorFont, toHaveTrait: .italicFontMask),
            .foregroundColor: ink,
            .paragraphStyle: authorStyle
        ]

        let sourceStyle = NSMutableParagraphStyle()
        sourceStyle.alignment = .center
        let sourceAttrs: [NSAttributedString.Key: Any] = [
            .font: sourceFont,
            .foregroundColor: ink,
            .paragraphStyle: sourceStyle,
            .kern: 2.0
        ]

        // Title block (centered vertically a bit above the middle).
        let titleString = NSAttributedString(string: input.title, attributes: titleAttrs)
        let titleRect = NSRect(x: 64, y: 320, width: width - 128, height: 280)
        titleString.draw(with: titleRect, options: [.usesLineFragmentOrigin], context: nil)

        // Decorative rule
        let ruleY: CGFloat = 300
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: width / 2 - 60, y: ruleY))
        rule.line(to: NSPoint(x: width / 2 + 60, y: ruleY))
        rule.lineWidth = 0.6
        rule.stroke()

        // Author
        if let author = input.author, !author.isEmpty {
            let authorString = NSAttributedString(string: author, attributes: authorAttrs)
            let authorRect = NSRect(x: 64, y: 250, width: width - 128, height: 32)
            authorString.draw(with: authorRect, options: [.usesLineFragmentOrigin], context: nil)
        }

        // Source (uppercase, tracked) at the bottom
        if let source = input.source, !source.isEmpty {
            let sourceString = NSAttributedString(string: source.uppercased(), attributes: sourceAttrs)
            let sourceRect = NSRect(x: 64, y: 70, width: width - 128, height: 24)
            sourceString.draw(with: sourceRect, options: [.usesLineFragmentOrigin], context: nil)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = context.makeImage() else { return nil }

        let mutableData = CFDataCreateMutable(nil, 0)!
        let typeId = (UTType.png.identifier as CFString)
        guard let dest = CGImageDestinationCreateWithData(mutableData, typeId, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
        #else
        return nil
        #endif
    }
}

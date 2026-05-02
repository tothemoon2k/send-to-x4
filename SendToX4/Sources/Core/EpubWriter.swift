import Foundation

/// Builds a complete EPUB 3 document in memory.
///
/// Inputs are deliberately structural: a list of chapters, optional cover,
/// optional images. The polish stage upstream is responsible for splitting
/// captured HTML into chapters. For a single-article capture we ship one
/// chapter; for a long piece with `<h1>` boundaries the polisher splits.
public enum EpubWriter {

    public struct Chapter {
        public var title: String
        public var bodyHTML: String          // already-sanitized XHTML body fragment
        public init(title: String, bodyHTML: String) {
            self.title = title
            self.bodyHTML = bodyHTML
        }
    }

    public struct Image {
        public var id: String                 // e.g. "img-001"
        public var filename: String           // e.g. "img-001.png"
        public var mediaType: String          // e.g. "image/png"
        public var data: Data
        public init(id: String, filename: String, mediaType: String, data: Data) {
            self.id = id
            self.filename = filename
            self.mediaType = mediaType
            self.data = data
        }
    }

    public struct Input {
        public var identifier: String        // urn:send-to-x4:<uuid> or canonical URL
        public var title: String
        public var author: String?
        public var sourceURL: String?
        public var sourceName: String?
        public var lang: String
        public var publishedTime: Date?
        public var chapters: [Chapter]
        public var coverPNG: Data?
        public var images: [Image]

        public init(
            identifier: String,
            title: String,
            author: String? = nil,
            sourceURL: String? = nil,
            sourceName: String? = nil,
            lang: String = "en",
            publishedTime: Date? = nil,
            chapters: [Chapter],
            coverPNG: Data? = nil,
            images: [Image] = []
        ) {
            self.identifier = identifier
            self.title = title
            self.author = author
            self.sourceURL = sourceURL
            self.sourceName = sourceName
            self.lang = lang
            self.publishedTime = publishedTime
            self.chapters = chapters
            self.coverPNG = coverPNG
            self.images = images
        }
    }

    public static func write(_ input: Input) throws -> Data {
        var entries: [ZipWriter.Entry] = []

        // 1. mimetype must be the FIRST entry, STORED, no extra fields.
        entries.append(.init(
            path: "mimetype",
            data: Data("application/epub+zip".utf8),
            method: .stored
        ))

        // 2. container.xml
        entries.append(.init(
            path: "META-INF/container.xml",
            data: Data(containerXML.utf8),
            method: .deflate
        ))

        // 3. style.css
        entries.append(.init(
            path: "OEBPS/style.css",
            data: Data(X4Stylesheet.css.utf8),
            method: .deflate
        ))

        // 4. cover image + cover xhtml
        if let cover = input.coverPNG {
            entries.append(.init(path: "OEBPS/cover.png", data: cover, method: .deflate))
            entries.append(.init(
                path: "OEBPS/cover.xhtml",
                data: Data(coverXHTML(input).utf8),
                method: .deflate
            ))
        }

        // 5. chapter files
        for (i, chapter) in input.chapters.enumerated() {
            let id = String(format: "chapter-%03d", i + 1)
            entries.append(.init(
                path: "OEBPS/\(id).xhtml",
                data: Data(chapterXHTML(chapter, lang: input.lang).utf8),
                method: .deflate
            ))
        }

        // 6. embedded images
        for img in input.images {
            entries.append(.init(
                path: "OEBPS/\(img.filename)",
                data: img.data,
                method: .deflate
            ))
        }

        // 7. nav.xhtml (EPUB 3 navigation document)
        entries.append(.init(
            path: "OEBPS/nav.xhtml",
            data: Data(navXHTML(input).utf8),
            method: .deflate
        ))

        // 8. content.opf — package metadata + manifest + spine
        entries.append(.init(
            path: "OEBPS/content.opf",
            data: Data(packageOPF(input).utf8),
            method: .deflate
        ))

        return try ZipWriter().write(entries: entries)
    }

    // MARK: - XML pieces

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func coverXHTML(_ input: Input) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(escapeAttr(input.lang))">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escapeXML(input.title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body class="cover" epub:type="cover">
          <figure>
            <img src="cover.png" alt="\(escapeAttr(input.title))"/>
          </figure>
        </body>
        </html>
        """
    }

    private static func chapterXHTML(_ chapter: Chapter, lang: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(escapeAttr(lang))">
        <head>
          <meta charset="UTF-8"/>
          <title>\(escapeXML(chapter.title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
          <section class="chapter" epub:type="chapter">
            <h1>\(escapeXML(chapter.title))</h1>
            \(chapter.bodyHTML)
          </section>
        </body>
        </html>
        """
    }

    private static func navXHTML(_ input: Input) -> String {
        var items = ""
        for (i, c) in input.chapters.enumerated() {
            let id = String(format: "chapter-%03d", i + 1)
            items += "<li><a href=\"\(id).xhtml\">\(escapeXML(c.title))</a></li>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(escapeAttr(input.lang))">
        <head>
          <meta charset="UTF-8"/>
          <title>Table of Contents</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
          <nav epub:type="toc" id="toc">
            <h1>Table of Contents</h1>
            <ol>
        \(items)    </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func packageOPF(_ input: Input) -> String {
        let modified = ISO8601DateFormatter.epubModified.string(from: Date())
        let pubDate = input.publishedTime.map { ISO8601DateFormatter.epubModified.string(from: $0) }

        var manifest = ""
        manifest += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        manifest += "<item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>\n"
        if input.coverPNG != nil {
            manifest += "<item id=\"cover-image\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>\n"
            manifest += "<item id=\"cover\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        }
        for (i, _) in input.chapters.enumerated() {
            let id = String(format: "chapter-%03d", i + 1)
            manifest += "<item id=\"\(id)\" href=\"\(id).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        }
        for img in input.images {
            manifest += "<item id=\"\(img.id)\" href=\"\(img.filename)\" media-type=\"\(img.mediaType)\"/>\n"
        }

        var spine = ""
        if input.coverPNG != nil {
            spine += "<itemref idref=\"cover\"/>\n"
        }
        spine += "<itemref idref=\"nav\"/>\n"
        for (i, _) in input.chapters.enumerated() {
            let id = String(format: "chapter-%03d", i + 1)
            spine += "<itemref idref=\"\(id)\"/>\n"
        }

        var meta = ""
        meta += "<dc:identifier id=\"pub-id\">\(escapeXML(input.identifier))</dc:identifier>\n"
        meta += "<dc:title>\(escapeXML(input.title))</dc:title>\n"
        meta += "<dc:language>\(escapeXML(input.lang))</dc:language>\n"
        if let author = input.author, !author.isEmpty {
            meta += "<dc:creator>\(escapeXML(author))</dc:creator>\n"
        }
        if let src = input.sourceURL, !src.isEmpty {
            meta += "<dc:source>\(escapeXML(src))</dc:source>\n"
        }
        if let publisher = input.sourceName, !publisher.isEmpty {
            meta += "<dc:publisher>\(escapeXML(publisher))</dc:publisher>\n"
        }
        if let pubDate = pubDate {
            meta += "<dc:date>\(escapeXML(pubDate))</dc:date>\n"
        }
        meta += "<meta property=\"dcterms:modified\">\(escapeXML(modified))</meta>\n"
        if input.coverPNG != nil {
            meta += "<meta name=\"cover\" content=\"cover-image\"/>\n"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" xml:lang="\(escapeAttr(input.lang))" unique-identifier="pub-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        \(meta)  </metadata>
          <manifest>
        \(manifest)  </manifest>
          <spine>
        \(spine)  </spine>
        </package>
        """
    }

    // MARK: - Escaping

    public static func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            default:   out.append(ch)
            }
        }
        return out
    }

    public static func escapeAttr(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&apos;"
            default:   out.append(ch)
            }
        }
        return out
    }
}

extension ISO8601DateFormatter {
    static let epubModified: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

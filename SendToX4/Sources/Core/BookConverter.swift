import Foundation

/// Coerces a book of any format into EPUB bytes. Strategy chain (highest
/// quality first):
///
///   - `.epub` → pass through unchanged.
///   - `.pdf`  → Claude PDF understanding + EpubWriter (best reflow, costs
///               tokens, slow). Falls through to Calibre on failure.
///   - everything else → Calibre `ebook-convert` shell-out.
public enum BookConverter {

    public struct Hint: Sendable {
        public var title: String
        public var authors: [String]
        public var lang: String?
        public var sourceURL: String?
        public var identifier: String

        public init(title: String, authors: [String], lang: String?, sourceURL: String?, identifier: String) {
            self.title = title
            self.authors = authors
            self.lang = lang
            self.sourceURL = sourceURL
            self.identifier = identifier
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case noConverterAvailable(format: String, detail: String)
        case calibreFailed(Int32, String)
        case claudePDFFailed(String)

        public var description: String {
            switch self {
            case .noConverterAvailable(let f, let detail):
                return "No converter available for format '\(f)': \(detail). Install Calibre (https://calibre-ebook.com) to enable broad-format conversion."
            case .calibreFailed(let code, let stderr):
                return "Calibre ebook-convert failed (exit \(code)): \(stderr.prefix(400))"
            case .claudePDFFailed(let msg):
                return "Claude PDF reflow failed: \(msg)"
            }
        }
    }

    public static func toEPUB(_ bytes: Data, format: String, hint: Hint, coverPNG: Data? = nil) async throws -> Data {
        // Trust the bytes, not the search-page label. AA's HTML sometimes
        // mis-tags a row, and our scraper can also miss the format hint —
        // detecting from file magic gets us the truth.
        let claimed = format.lowercased()
        let detected = Self.sniffFormat(bytes: bytes) ?? claimed
        if detected != claimed {
            fputs("[converter] format claim '\(claimed)' overridden by byte-magic detection: '\(detected)'\n", stderr)
        }

        switch detected {
        case "epub":
            // Pass-through. Inject a cover only if the EPUB doesn't already
            // have one — most AA EPUBs do, and re-injection over an existing
            // cover risks duplicate spine entries.
            guard let coverPNG else { return bytes }
            return EpubCoverInjector.ensureCover(bytes, coverPNG: coverPNG, title: hint.title, lang: hint.lang ?? "en")
        case "txt":
            return try convertTXT(bytes, hint: hint, coverPNG: coverPNG)
        case "pdf":
            // Claude PDF reflow first (better than Calibre on small e-ink for
            // text-heavy PDFs). Calibre as a last resort if Claude is unavailable.
            do {
                return try await convertPDFViaClaude(bytes, hint: hint, coverPNG: coverPNG)
            } catch {
                fputs("[converter] Claude PDF reflow failed (\(error)); trying Calibre as fallback\n", stderr)
                let calibreOut = try convertViaCalibre(bytes, format: detected, hint: hint, coverPNG: coverPNG)
                guard let coverPNG else { return calibreOut }
                // Belt-and-braces: Calibre's --cover usually works, but if
                // anything slipped through (older Calibre, weird input)
                // ensureCover will replace whatever's there.
                return EpubCoverInjector.ensureCover(calibreOut, coverPNG: coverPNG, title: hint.title, lang: hint.lang ?? "en")
            }
        default:
            // MOBI / AZW3 / DJVU / DOCX / FB2 etc. — Calibre is the only
            // open-source option that handles these accurately. We surface a
            // clear, actionable error if it's not installed instead of
            // dropping the user into a cryptic "convert failed" state.
            let calibreOut = try convertViaCalibre(bytes, format: detected, hint: hint, coverPNG: coverPNG)
            guard let coverPNG else { return calibreOut }
            return EpubCoverInjector.ensureCover(calibreOut, coverPNG: coverPNG, title: hint.title, lang: hint.lang ?? "en")
        }
    }

    /// File-magic sniffer. Returns the format we're confident about from the
    /// first kilobytes of the payload, or nil to defer to whatever the caller
    /// claimed.
    public static func sniffFormat(bytes: Data) -> String? {
        if bytes.count >= 4 {
            // EPUB is a ZIP whose first entry is "mimetype" containing
            // "application/epub+zip" right after the local file header.
            if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
                let mimeNeedle = Data("application/epub+zip".utf8)
                if bytes.prefix(200).range(of: mimeNeedle) != nil {
                    return "epub"
                }
                // Office ZIPs (.docx) carry a [Content_Types].xml first.
                let docxNeedle = Data("[Content_Types].xml".utf8)
                if bytes.prefix(200).range(of: docxNeedle) != nil {
                    return "docx"
                }
                // Otherwise: unknown ZIP — could still be CBZ/EPUB w/ broken
                // ordering. Don't claim a format we're not sure about.
                return nil
            }
            if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {     // %PDF
                return "pdf"
            }
        }
        // MOBI / AZW3: the PalmDB record header has "BOOKMOBI" at offset 60.
        if bytes.count >= 68 {
            let needle = Data("BOOKMOBI".utf8)
            if bytes.subdata(in: 60..<68) == needle {
                return "mobi"
            }
        }
        // DJVU container starts with "AT&TFORM".
        if bytes.count >= 8 {
            let needle = Data("AT&TFORM".utf8)
            if bytes.prefix(8) == needle {
                return "djvu"
            }
        }
        // FB2 is XML; cheap check on the first KB.
        if let head = String(data: bytes.prefix(2048), encoding: .utf8),
           head.contains("<FictionBook") {
            return "fb2"
        }
        // TXT: high ratio of printable ASCII in the first 4 KB.
        let probe = bytes.prefix(4096)
        if !probe.isEmpty {
            let printable = probe.reduce(0) { acc, b in
                // Tab, LF, CR, space..tilde
                let ok = b == 0x09 || b == 0x0A || b == 0x0D || (b >= 0x20 && b <= 0x7E) || b >= 0x80
                return acc + (ok ? 1 : 0)
            }
            if Double(printable) / Double(probe.count) > 0.97 {
                return "txt"
            }
        }
        return nil
    }

    // MARK: - TXT → EPUB (native, no external deps)

    private static func convertTXT(_ bytes: Data, hint: Hint, coverPNG: Data? = nil) throws -> Data {
        // Try UTF-8, fall back to latin-1 so we don't choke on older TXT
        // dumps (Project Gutenberg ships some files in ISO-8859-1).
        let text = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Paragraph break = blank line. Each paragraph becomes one <p>.
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let html = paragraphs
            .map { "<p>\(Self.xhtmlEscape($0).replacingOccurrences(of: "\n", with: "<br/>"))</p>" }
            .joined(separator: "\n")

        let input = EpubWriter.Input(
            identifier: hint.identifier,
            title: hint.title,
            author: hint.authors.first,
            sourceURL: hint.sourceURL,
            sourceName: nil,
            lang: hint.lang ?? "en",
            publishedTime: nil,
            chapters: [.init(title: hint.title, bodyHTML: html)],
            coverPNG: coverPNG,
            images: []
        )
        return try EpubWriter.write(input)
    }

    private static func xhtmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - PDF → Claude → EpubWriter

    private static func convertPDFViaClaude(_ bytes: Data, hint: Hint, coverPNG: Data? = nil) async throws -> Data {
        guard let key = SettingsStore.shared.anthropicAPIKey(), !key.isEmpty else {
            throw Error.claudePDFFailed("Anthropic API key not set")
        }

        let systemPrompt = """
        You are converting a scanned/digital PDF book into clean reflowable \
        XHTML chapters for a small e-ink reader.

        HARD RULES:

        1. Preserve all body text verbatim — every word, in original order. \
           NEVER paraphrase, summarize, translate, or reword.
        2. Split into chapters at natural boundaries (chapter headings, part \
           breaks). For each chapter return `{ heading, html }`.
        3. The `html` strings must be well-formed XHTML fragments (self-closing \
           void elements like <br/>, <hr/>, all attributes quoted, ampersands \
           escaped). Use <p>, <h1>–<h3>, <em>, <strong>, <blockquote>, <ol>, \
           <ul>, <li>. Do NOT include <html>, <head>, <body>, scripts, styles, \
           or class names.
        4. Drop running headers/footers, page numbers, library stamps, and \
           OCR artifacts. Keep all author content (footnotes, dedications, \
           epigraphs).
        5. If the PDF is image-heavy and lacks meaningful selectable text, \
           do your best to extract any captions or visible text — DO NOT \
           hallucinate body content.
        6. Output ONLY valid JSON: { "chapters": [{ "heading": string, "html": string }] } \
           — no markdown fences, no commentary.
        """

        let pdfB64 = bytes.base64EncodedString()
        let userPrompt = """
        Title hint: \(hint.title)
        Author hint: \(hint.authors.joined(separator: ", "))

        Convert the attached PDF to chapters. Body text is sacred — verbatim only.
        """

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 64000,
            "system": [
                ["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]
            ],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "document",
                            "source": [
                                "type": "base64",
                                "media_type": "application/pdf",
                                "data": pdfB64
                            ]
                        ],
                        ["type": "text", "text": userPrompt]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.claudePDFFailed("no response")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Error.claudePDFFailed("HTTP \(http.statusCode): \(text.prefix(300))")
        }
        let envelope = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let textBlock = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw Error.claudePDFFailed("no text block in response")
        }
        let trimmed = JSONHelpers.stripJSONFence(textBlock)
        guard let payloadData = trimmed.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw Error.claudePDFFailed("model output didn't match the expected JSON shape: \(trimmed.prefix(200))")
        }
        guard !payload.chapters.isEmpty else {
            throw Error.claudePDFFailed("model returned zero chapters")
        }

        let input = EpubWriter.Input(
            identifier: hint.identifier,
            title: hint.title,
            author: hint.authors.first,
            sourceURL: hint.sourceURL,
            sourceName: nil,
            lang: hint.lang ?? "en",
            publishedTime: nil,
            chapters: payload.chapters.map { .init(title: $0.heading, bodyHTML: $0.html) },
            coverPNG: coverPNG,
            images: []
        )
        return try EpubWriter.write(input)
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        struct ContentBlock: Decodable { let type: String; let text: String? }
    }

    private struct Payload: Decodable {
        let chapters: [Ch]
        struct Ch: Decodable { let heading: String; let html: String }
    }

    // MARK: - Calibre

    /// Hard-coded macOS install path first; PATH lookup as a fallback.
    private static func locateCalibre() -> URL? {
        let app = URL(fileURLWithPath: "/Applications/calibre.app/Contents/MacOS/ebook-convert")
        if FileManager.default.isExecutableFile(atPath: app.path) {
            return app
        }
        // PATH lookup via /usr/bin/env which.
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = ["ebook-convert"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func convertViaCalibre(_ bytes: Data, format: String, hint: Hint, coverPNG: Data? = nil) throws -> Data {
        guard let calibre = locateCalibre() else {
            throw Error.noConverterAvailable(
                format: format,
                detail: "ebook-convert not found at /Applications/calibre.app/... or on PATH"
            )
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sendtox4-conv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let inputExt = format.isEmpty ? "bin" : format
        let inputURL = tmp.appendingPathComponent("input.\(inputExt)")
        let outputURL = tmp.appendingPathComponent("output.epub")
        try bytes.write(to: inputURL, options: [.atomic])

        var args: [String] = [inputURL.path, outputURL.path]
        if !hint.title.isEmpty {
            args.append(contentsOf: ["--title", hint.title])
        }
        if !hint.authors.isEmpty {
            args.append(contentsOf: ["--authors", hint.authors.joined(separator: " & ")])
        }
        if let lang = hint.lang, !lang.isEmpty {
            args.append(contentsOf: ["--language", lang])
        }
        // Provide our cover so Calibre embeds it instead of generating its
        // default "stack of books with calibre 0.x watermark" placeholder.
        if let coverPNG {
            let coverURL = tmp.appendingPathComponent("cover.png")
            try coverPNG.write(to: coverURL, options: [.atomic])
            args.append(contentsOf: ["--cover", coverURL.path])
        }
        // Output in EPUB 3 — newer EPUBs have better reflow and the X4
        // accepts both 2 and 3 (per CrossPoint renderer docs).
        args.append(contentsOf: ["--epub-version", "3"])

        let process = Process()
        process.executableURL = calibre
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = (String(data: errData, encoding: .utf8) ?? "")
                + "\n"
                + (String(data: outData, encoding: .utf8) ?? "")
            throw Error.calibreFailed(process.terminationStatus, msg)
        }

        return try Data(contentsOf: outputURL)
    }
}

import Foundation

/// Adds a cover image to an EPUB that doesn't already have one.
///
/// AA EPUBs *usually* embed a cover, but not always — especially older
/// scans or stripped versions. This module:
///   1. Inspects the EPUB's OPF for an existing cover (manifest item with
///      `properties="cover-image"`, or the EPUB-2 `<meta name="cover">`
///      hint). If one exists, returns the bytes unchanged.
///   2. Otherwise: extracts the EPUB to a temp dir, drops a `cover.png` and
///      `cover.xhtml` next to the OPF, patches the OPF manifest + spine,
///      and re-zips via `ZipWriter` (mimetype STORED first, per spec).
///
/// Falls back to the original bytes on any unexpected parse failure rather
/// than producing a broken EPUB.
public enum EpubCoverInjector {

    public enum Error: Swift.Error, CustomStringConvertible {
        case unzipFailed(Int32)
        case opfNotFound
        public var description: String {
            switch self {
            case .unzipFailed(let code): return "unzip failed with status \(code)"
            case .opfNotFound: return "EPUB container.xml didn't point at any OPF"
            }
        }
    }

    /// Forces the supplied PNG to be the EPUB's cover, replacing any existing
    /// cover declaration. The og:image / Open Library cover we feed in is
    /// almost always better than what's baked into AA EPUBs (which include
    /// Calibre 0.x placeholders, low-res scans, watermarked thumbnails, …).
    /// On any unexpected parse failure we return the original bytes untouched
    /// rather than producing a broken EPUB.
    public static func ensureCover(_ epubBytes: Data, coverPNG: Data, title: String, lang: String) -> Data {
        do {
            return try inject(epubBytes, coverPNG: coverPNG, title: title, lang: lang)
        } catch {
            fputs("[cover] injection skipped (\(error)); passing EPUB through unchanged\n", stderr)
            return epubBytes
        }
    }

    // MARK: -

    private static func inject(_ epubBytes: Data, coverPNG: Data, title: String, lang: String) throws -> Data {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sendtox4-cover-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let inputURL = work.appendingPathComponent("input.epub")
        try epubBytes.write(to: inputURL)

        let extractDir = work.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try runUnzip(inputURL: inputURL, destination: extractDir)

        let containerURL = extractDir.appendingPathComponent("META-INF/container.xml")
        guard let containerXML = try? String(contentsOf: containerURL, encoding: .utf8),
              let opfRel = parseOPFPath(containerXML) else {
            throw Error.opfNotFound
        }
        let opfURL = extractDir.appendingPathComponent(opfRel)
        guard var opfXML = try? String(contentsOf: opfURL, encoding: .utf8) else {
            throw Error.opfNotFound
        }

        // Strip any existing cover declarations BEFORE patching ours in.
        // Without this, AA EPUBs with a baked-in Calibre placeholder cover
        // would keep showing the placeholder (the X4 picks up whichever
        // <item properties="cover-image"/> appears first, and a duplicate
        // declaration is malformed anyway).
        opfXML = stripExistingCover(opfXML)

        // Place cover assets in the OPF's directory so relative hrefs work.
        // If the original EPUB had a cover.png at this exact path, we
        // overwrite it — that's a feature, not a bug: the placeholder bytes
        // get replaced with our own.
        let opfDir = (opfRel as NSString).deletingLastPathComponent
        let coverPNGRel = opfDir.isEmpty ? "cover.png" : "\(opfDir)/cover.png"
        let coverXHTMLRel = opfDir.isEmpty ? "cover.xhtml" : "\(opfDir)/cover.xhtml"

        try coverPNG.write(to: extractDir.appendingPathComponent(coverPNGRel))
        try coverXHTML(title: title, lang: lang)
            .data(using: .utf8)!
            .write(to: extractDir.appendingPathComponent(coverXHTMLRel))

        opfXML = patchOPF(opfXML)
        try opfXML.data(using: .utf8)!.write(to: opfURL)

        return try repack(extractDir: extractDir)
    }

    // MARK: - OPF parsing / patching

    /// Returns true if the OPF already declares a cover image.
    public static func hasCover(_ opfXML: String) -> Bool {
        // EPUB 3: properties="cover-image" on a manifest item.
        if opfXML.range(of: #"properties\s*=\s*"[^"]*\bcover-image\b"#, options: .regularExpression) != nil {
            return true
        }
        // EPUB 2: <meta name="cover" content="..."/>.
        if opfXML.range(of: #"<meta[^>]*name\s*=\s*"cover""#, options: .regularExpression) != nil {
            return true
        }
        // Heuristic: a manifest item whose href looks like a cover.
        if opfXML.range(of: #"href\s*=\s*"[^"]*cover[^"]*\.(jpe?g|png|gif|webp)""#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    /// Strips every existing cover declaration from an OPF so a fresh one can
    /// be patched in without conflicts. Removes:
    ///   - `properties="cover-image"` (and just that property — the manifest
    ///     item itself stays so we don't break unrelated references).
    ///   - EPUB-2 `<meta name="cover" content="…"/>` hints.
    ///   - Our own previously-injected cover items / spine itemref (so a
    ///     re-run with a different cover image doesn't double up).
    public static func stripExistingCover(_ opf: String) -> String {
        var out = opf
        // Remove `properties="cover-image"` (preserve other property tokens
        // like `nav` if they share the attribute).
        out = stripCoverImageProperty(out)
        // Drop EPUB-2 cover meta hints regardless of their content.
        out = out.replacingOccurrences(
            of: #"\s*<meta[^>]*name\s*=\s*"cover"[^>]*/?>\s*"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop our previously-injected manifest items + spine itemref so
        // re-injection doesn't duplicate them.
        out = out.replacingOccurrences(
            of: #"\s*<item[^>]*id\s*=\s*"stx4-cover(-image)?"[^>]*/?>\s*"#,
            with: "\n",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\s*<itemref[^>]*idref\s*=\s*"stx4-cover"[^>]*/?>\s*"#,
            with: "\n",
            options: .regularExpression
        )
        return out
    }

    /// Removes only the `cover-image` token from `properties="…"` attributes,
    /// leaving the manifest item and any other property tokens intact. We do
    /// this rather than dropping the whole item because the underlying image
    /// might still be referenced by other XHTML pages.
    private static func stripCoverImageProperty(_ opf: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"properties\s*=\s*"([^"]*)""#, options: []) else {
            return opf
        }
        let ns = opf as NSString
        let matches = regex.matches(in: opf, range: NSRange(location: 0, length: ns.length))
        // Walk in reverse so earlier ranges remain valid as we mutate.
        var out = opf
        for m in matches.reversed() {
            let valueRange = m.range(at: 1)
            let value = ns.substring(with: valueRange)
            let cleaned = value
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty && $0 != "cover-image" }
                .joined(separator: " ")
            if cleaned == value { continue }                  // no change
            let outNS = out as NSString
            // Re-locate by searching from the current absolute offset; the
            // matches array was built against `opf`, but as we strip earlier
            // matches we need to recompute. Simpler: rebuild via regex pass.
            _ = outNS  // unused, satisfies the linter
            if cleaned.isEmpty {
                // Drop the whole `properties="…"` attribute (and any
                // immediately preceding whitespace).
                out = out.replacingOccurrences(
                    of: #"\s*properties\s*=\s*"\#(NSRegularExpression.escapedPattern(for: value))""#,
                    with: "",
                    options: .regularExpression
                )
            } else {
                out = out.replacingOccurrences(
                    of: "properties=\"\(value)\"",
                    with: "properties=\"\(cleaned)\""
                )
            }
        }
        return out
    }

    /// Pulls the OPF's relative path out of `META-INF/container.xml`.
    public static func parseOPFPath(_ containerXML: String) -> String? {
        // <rootfile full-path="OEBPS/content.opf" …>
        let pattern = #"full-path\s*=\s*"([^"]+)""#
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = containerXML as NSString
        guard let m = r.firstMatch(in: containerXML, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// Inserts cover-image manifest items + a leading spine itemref + the
    /// EPUB-2 `<meta name="cover">` hint. Done with regex string surgery
    /// rather than full XML reserialization to keep the rest of the OPF
    /// byte-identical (some readers care about ordering).
    public static func patchOPF(_ opfXML: String) -> String {
        var out = opfXML
        let manifestInsert = """
        <item id="stx4-cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
        <item id="stx4-cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
        """
        let spineInsert = #"<itemref idref="stx4-cover" linear="yes"/>"#
        let metaInsert = #"<meta name="cover" content="stx4-cover-image"/>"#

        // Insert manifest items just before </manifest>.
        if let r = out.range(of: "</manifest>") {
            out.replaceSubrange(r, with: manifestInsert + "\n</manifest>")
        }
        // Insert spine itemref right after <spine ...>.
        if let r = out.range(of: #"<spine[^>]*>"#, options: .regularExpression) {
            let insertAt = r.upperBound
            out.insert(contentsOf: "\n" + spineInsert, at: insertAt)
        }
        // Insert <meta name="cover"> right after <metadata ...>.
        if out.range(of: #"<meta[^>]*name\s*=\s*"cover""#, options: .regularExpression) == nil {
            if let r = out.range(of: #"<metadata[^>]*>"#, options: .regularExpression) {
                let insertAt = r.upperBound
                out.insert(contentsOf: "\n" + metaInsert, at: insertAt)
            }
        }
        return out
    }

    private static func coverXHTML(title: String, lang: String) -> String {
        let safeTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)">
        <head>
          <meta charset="UTF-8"/>
          <title>\(safeTitle)</title>
          <style>body{margin:0;padding:0;text-align:center;}img{max-width:100%;max-height:100vh;}</style>
        </head>
        <body class="cover" epub:type="cover">
          <figure><img src="cover.png" alt="\(safeTitle)"/></figure>
        </body>
        </html>
        """
    }

    // MARK: - Process / re-pack

    private static func runUnzip(inputURL: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", inputURL.path, "-d", destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw Error.unzipFailed(process.terminationStatus)
        }
    }

    private static func repack(extractDir: URL) throws -> Data {
        let fm = FileManager.default
        var entries: [ZipWriter.Entry] = []

        // mimetype MUST be the first entry, STORED, no extra fields. Check
        // its presence first; fall back to a fresh one if a malformed input
        // somehow shipped without one (would have failed validation anyway).
        let mimeURL = extractDir.appendingPathComponent("mimetype")
        let mimeData: Data
        if fm.fileExists(atPath: mimeURL.path) {
            mimeData = (try? Data(contentsOf: mimeURL)) ?? Data("application/epub+zip".utf8)
        } else {
            mimeData = Data("application/epub+zip".utf8)
        }
        entries.append(.init(path: "mimetype", data: mimeData, method: .stored))

        // Walk every other file in deterministic order so re-injection of
        // the same EPUB twice yields byte-identical output (helps the X4's
        // upload-by-name+size dedupe).
        var files: [String] = []
        // macOS resolves the temporary directory through a `/private/var` →
        // `/var` symlink, so URL.path and extractDir.path can disagree on
        // which prefix appears. Standardize both before stripping.
        let basePath = extractDir.standardizedFileURL.path
        if let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                let abs = url.standardizedFileURL.path
                let prefix = basePath + "/"
                let rel = abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : abs
                if rel == "mimetype" { continue }
                files.append(rel)
            }
        }
        files.sort()
        for rel in files {
            let url = extractDir.appendingPathComponent(rel)
            guard let data = try? Data(contentsOf: url) else { continue }
            entries.append(.init(path: rel, data: data, method: .deflate))
        }

        return try ZipWriter().write(entries: entries)
    }
}

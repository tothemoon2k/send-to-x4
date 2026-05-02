import Foundation

/// Anna's Archive client: domain discovery (via Wikipedia, then probe),
/// search (HTML scrape — there is no JSON search API), and fast-download
/// (the only stable JSON endpoint, member-key gated).
public actor AnnasArchive {

    public static let shared = AnnasArchive()

    public struct Candidate: Sendable {
        public var md5: String
        public var format: String           // "epub", "pdf", "azw3", …
        public var sizeBytes: Int?
        public var lang: String?            // best-effort, e.g. "en"
        public var title: String?
        public var authors: String?
        public var sourceText: String       // the full anchor text, for debugging

        public init(md5: String, format: String, sizeBytes: Int?, lang: String?, title: String?, authors: String?, sourceText: String) {
            self.md5 = md5
            self.format = format
            self.sizeBytes = sizeBytes
            self.lang = lang
            self.title = title
            self.authors = authors
            self.sourceText = sourceText
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case noMirrorReachable
        case searchFailed(Int, String)
        case fastDownloadFailed(String)
        case noCandidates(String)
        case missingMemberKey

        public var description: String {
            switch self {
            case .noMirrorReachable:
                return "Couldn't reach Anna's Archive on any known mirror. Wikipedia + hardcoded fallback list all failed; check your network connection."
            case .searchFailed(let code, let body):
                return "Anna's Archive search failed (HTTP \(code)): \(body.prefix(200))"
            case .fastDownloadFailed(let msg):
                return "Anna's Archive fast download failed: \(msg)"
            case .noCandidates(let q):
                return "No download candidates for query: \(q)"
            case .missingMemberKey:
                return "Anna's Archive member key not set. Run tools/setaakey.sh after starting the daemon."
            }
        }
    }

    /// Hardcoded fallback if Wikipedia scrape itself fails. Order matters —
    /// these are probed in this order.
    public static let fallbackMirrors: [String] = [
        "annas-archive.org",
        "annas-archive.se",
        "annas-archive.li"
    ]

    private var activeMirror: URL?
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = [
            // Without a UA, AA sometimes returns a stub page.
            "User-Agent": "SendToX4/1.0 (+https://github.com/tothemoon2k/send-to-x4)"
        ]
        return URLSession(configuration: cfg)
    }()

    public init() {}

    // MARK: - Mirror discovery

    public func resolveMirror() async throws -> URL {
        if let m = activeMirror { return m }

        var hosts = (try? await scrapeWikipediaHosts()) ?? []
        for fallback in Self.fallbackMirrors where !hosts.contains(fallback) {
            hosts.append(fallback)
        }

        for host in hosts {
            guard let url = URL(string: "https://\(host)/") else { continue }
            if await isReachable(url) {
                activeMirror = url
                return url
            }
        }
        throw Error.noMirrorReachable
    }

    /// Forces re-discovery on next request — call this if a request to the
    /// cached mirror fails with a connection error.
    public func invalidateMirror() {
        activeMirror = nil
    }

    private func scrapeWikipediaHosts() async throws -> [String] {
        guard let url = URL(string: "https://en.wikipedia.org/wiki/Anna%27s_Archive") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        // Match the bare host of any `annas-archive.<tld>[.<tld>]` URL.
        let pattern = "annas-archive\\.[a-z]+(?:\\.[a-z]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var seen = Set<String>()
        var ordered: [String] = []
        for m in matches {
            let host = nsHTML.substring(with: m.range).lowercased()
            if seen.insert(host).inserted {
                ordered.append(host)
            }
        }
        return ordered
    }

    private func isReachable(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            // 200 / 301 / 302 / 403 (Cloudflare gate) — anything that proves
            // the host is alive and routable counts. The actual search call
            // will fail loudly later if AA is broken.
            return (200...499).contains(http.statusCode) && http.statusCode != 404
        } catch {
            return false
        }
    }

    // MARK: - Search (HTML scrape)

    /// EPUB-first two-pass search. The X4 only reads EPUB and the converter
    /// chain is much simpler when we don't have to convert at all, so we
    /// strongly prefer EPUB candidates: pass 1 narrows the AA query to
    /// `ext=epub`, pass 2 (only if pass 1 returned nothing) widens to all
    /// formats so we can still find rarer books.
    public func search(query: String, preferredLang: String?) async throws -> [Candidate] {
        let epubOnly = try await runSearch(query: query, ext: "epub")
        if !epubOnly.isEmpty {
            return epubOnly
        }
        return try await runSearch(query: query, ext: nil)
    }

    private func runSearch(query: String, ext: String?) async throws -> [Candidate] {
        let mirror = try await resolveMirror()
        var comps = URLComponents(url: mirror.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: query)]
        if let ext { items.append(URLQueryItem(name: "ext", value: ext)) }
        comps.queryItems = items
        guard let url = comps.url else { throw Error.searchFailed(-1, "bad search URL") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Error.searchFailed(-1, "no response")
        }
        if http.statusCode != 200 {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw Error.searchFailed(http.statusCode, String(snippet))
        }

        var candidates = Self.parseSearchHTML(data, preferredLang: nil)
        // If we filtered by ext=epub, AA still sometimes returns rows where
        // our parser couldn't pin the format from the row text — but we know
        // it's epub because of the filter. Promote those.
        if ext == "epub" {
            candidates = candidates.map { c in
                var copy = c
                if copy.format == "unknown" { copy.format = "epub" }
                return copy
            }
        }
        return candidates
    }

    /// Pulls candidates out of the search-results HTML. AA wraps each result
    /// in `<a href="/md5/<hash>" …>` with the format/size/language sitting in
    /// the inner text. Class names rotate on the live site, so we lean on the
    /// `/md5/` href + a tolerant regex over the anchor text rather than CSS.
    public static func parseSearchHTML(_ data: Data, preferredLang: String?) -> [Candidate] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        // Some result rows are inside `<!-- -->` HTML comments to defer JS
        // hydration. Strip those before regexing — they hide perfectly good
        // candidates from a naive scan.
        let unwrapped = html
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")

        // `<a … href="/md5/<32-hex-char>"…>…</a>` with non-greedy body.
        let pattern = #"<a[^>]*href=\"/md5/([a-f0-9]{32})\"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let ns = unwrapped as NSString
        let matches = regex.matches(in: unwrapped, range: NSRange(location: 0, length: ns.length))

        var seen = Set<String>()
        var out: [Candidate] = []
        for m in matches {
            guard m.numberOfRanges == 3 else { continue }
            let md5 = ns.substring(with: m.range(at: 1)).lowercased()
            if !seen.insert(md5).inserted { continue }
            let inner = ns.substring(with: m.range(at: 2))
            // Look for the format token in BOTH the rendered text and any
            // attribute values: AA increasingly tucks format hints into
            // `alt`/`title`/`data-*` attributes that stripTags would discard.
            let text = stripTags(inner)
            let format = Self.detectFormat(text)
                ?? Self.detectFormat(inner)
                ?? "unknown"
            let size = Self.detectSize(text)
            let lang = Self.detectLang(text)

            out.append(Candidate(
                md5: md5,
                format: format.lowercased(),
                sizeBytes: size,
                lang: lang,
                title: nil,
                authors: nil,
                sourceText: String(text.prefix(400))
            ))
        }
        return out
    }

    private static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; out.append(" "); continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "[ \t\n\r]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func detectFormat(_ text: String) -> String? {
        let pattern = #"\b(epub|azw3|azw|mobi|fb2|djvu|docx|doc|pdf|cbr|cbz|txt)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func detectSize(_ text: String) -> Int? {
        let pattern = #"(\d+(?:\.\d+)?)\s*(MB|KB|GB|B)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
        let unit = ns.substring(with: m.range(at: 2)).uppercased()
        let factor: Double
        switch unit {
        case "GB": factor = 1024 * 1024 * 1024
        case "MB": factor = 1024 * 1024
        case "KB": factor = 1024
        default:   factor = 1
        }
        return Int(n * factor)
    }

    static func detectLang(_ text: String) -> String? {
        // First look for an explicit BCP-47-ish marker in brackets: "[en]", "[ru]"
        let bracket = #"\[([a-z]{2,3})\]"#
        if let r = try? NSRegularExpression(pattern: bracket, options: [.caseInsensitive]) {
            let ns = text as NSString
            if let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: m.range(at: 1)).lowercased()
            }
        }
        // Fall back to a tiny English-name lookup. Order roughly by frequency.
        let names: [(String, String)] = [
            ("english", "en"), ("french", "fr"), ("german", "de"),
            ("spanish", "es"), ("russian", "ru"), ("italian", "it"),
            ("portuguese", "pt"), ("chinese", "zh"), ("japanese", "ja"),
            ("dutch", "nl"), ("polish", "pl"), ("arabic", "ar"),
            ("turkish", "tr"), ("ukrainian", "uk"), ("korean", "ko")
        ]
        let lower = text.lowercased()
        for (name, code) in names where lower.contains(name) {
            return code
        }
        return nil
    }

    // MARK: - Candidate ranking

    public static func pickBest(_ candidates: [Candidate], preferredLang: String?) -> Candidate? {
        // Reject unknown-format candidates outright. Better to fail the build
        // with "no candidates" than to download an unidentifiable blob and
        // surprise the converter chain with random bytes.
        let known = candidates.filter { $0.format != "unknown" }
        guard !known.isEmpty else { return nil }

        func score(_ c: Candidate) -> Double {
            var s: Double = 0
            switch c.format {
            case "epub": s += 100
            case "azw3": s += 80
            case "mobi": s += 75
            case "fb2":  s += 70
            case "docx", "doc": s += 60
            case "txt":  s += 50
            case "djvu": s += 30
            case "pdf":  s += 20
            default:     s += 10
            }

            if let want = preferredLang?.lowercased(), let got = c.lang, got == want {
                s += 50
            } else if preferredLang == nil, c.lang == "en" {
                s += 20
            }

            if let bytes = c.sizeBytes {
                if bytes < 50 * 1024 {
                    s -= 40                       // probably a sample
                } else if bytes < 200 * 1024 {
                    s -= 10
                } else if bytes <= 30 * 1024 * 1024 {
                    s += 5
                } else if bytes <= 200 * 1024 * 1024 {
                    s -= 10                       // huge files reflow slowly on e-ink
                } else {
                    s -= 30
                }
            }
            return s
        }

        // Stable: enumerated() preserves search-order tiebreaks (Anna ranks first).
        return known.enumerated()
            .max(by: { lhs, rhs in
                let ls = score(lhs.element)
                let rs = score(rhs.element)
                if ls != rs { return ls < rs }
                return lhs.offset > rhs.offset
            })?
            .element
    }

    // MARK: - Fast download

    public func fastDownloadURL(md5: String, key: String) async throws -> URL {
        let mirror = try await resolveMirror()
        var comps = URLComponents(url: mirror.appendingPathComponent("dyn/api/fast_download.json"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "md5", value: md5),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = comps.url else { throw Error.fastDownloadFailed("bad URL") }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Error.fastDownloadFailed("no response")
        }
        // 200 or 204 are documented success codes.
        let envelope = try? JSONDecoder().decode(FastDownloadResponse.self, from: data)
        if (http.statusCode == 200 || http.statusCode == 204), let dl = envelope?.download_url, let resolved = URL(string: dl) {
            return resolved
        }
        let msg = envelope?.error
            ?? String(data: data, encoding: .utf8)?.prefix(200).description
            ?? "HTTP \(http.statusCode)"
        throw Error.fastDownloadFailed(msg)
    }

    private struct FastDownloadResponse: Decodable {
        let download_url: String?
        let error: String?
    }

    // MARK: - File download

    /// Streams the resolved fast-download URL into memory. Anna's partner
    /// servers serve the raw file bytes — no extra unwrapping needed.
    public func downloadFile(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Error.fastDownloadFailed("download HTTP \(code)")
        }
        return data
    }
}

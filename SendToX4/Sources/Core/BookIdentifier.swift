import Foundation

/// Looks at the page in front of the user (URL + title + a text snippet) and
/// asks Claude what book it is. Returns canonical title + authors so the
/// next stage can search Anna's Archive.
///
/// Mirrors the Anthropic-call conventions in `ClaudePolish.swift`: same model,
/// same headers, same prompt-cache pattern, same Keychain-backed key.
public enum BookIdentifier {

    public struct Identified: Sendable {
        public var isBookPage: Bool
        public var title: String
        public var authors: [String]
        public var isbn13: String?
        public var lang: String?
        public var year: Int?
        public var confidence: Double
    }

    public struct Input: Sendable {
        public var url: String
        public var title: String?
        public var lang: String?
        public var snippet: String

        public init(url: String, title: String?, lang: String?, snippet: String) {
            self.url = url
            self.title = title
            self.lang = lang
            self.snippet = snippet
        }
    }

    public enum Error: Swift.Error {
        case missingAPIKey
        case httpError(Int, String)
        case decodeError(String)
    }

    public static let model = "claude-sonnet-4-6"

    public static let systemPrompt = """
    You identify which book a webpage is primarily about.

    The user is reading a page somewhere on the open web (Project Gutenberg, \
    Goodreads, Amazon, Wikipedia, a publisher's site, a blog about books, \
    etc.) and wants to download that book to a small e-ink reader. Your only \
    job is to look at the URL, page title, and a snippet of body text, and \
    return canonical bibliographic identifiers a search system can use.

    HARD RULES:

    1. Decide whether the page is *primarily about a single specific book*. \
       A book detail page (Goodreads /book/show/, Amazon product page for a \
       book, Project Gutenberg ebook page, Wikipedia article whose subject \
       is a single book, publisher catalog page) qualifies. A search-results \
       page, an author bibliography page, a homepage, a news article, a list \
       of books, or a page about a film/TV adaptation does NOT qualify.

    2. If it does not qualify, return:
       { "isBookPage": false, "title": "", "authors": [], "isbn13": null, \
       "lang": null, "year": null, "confidence": 0.0 }

    3. If it does qualify, return canonical metadata:
       - `title`: the canonical book title, in the original language if known. \
         Strip subtitles after a colon ONLY if they're clearly editorial \
         additions ("Crime and Punishment: A Novel" → "Crime and Punishment"). \
         Keep subtitles that are part of the work ("Sapiens: A Brief History \
         of Humankind").
       - `authors`: array of primary author(s), in "Firstname Lastname" form. \
         Empty array if genuinely unknown. Do NOT include translators or \
         editors unless the work is anthological.
       - `isbn13`: 13-digit ISBN if visible on the page, else null. Strip \
         hyphens and spaces.
       - `lang`: BCP-47 code of the original work language (e.g. "en", "ru", \
         "fr"), not the page language. Null if unsure.
       - `year`: original publication year as an integer, or null.
       - `confidence`: 0.0–1.0 self-rating. Use ≥0.8 for high-signal pages \
         (Goodreads /book/show/, Project Gutenberg /ebooks/N, Amazon book \
         product page); 0.6–0.8 for solid Wikipedia / publisher pages; \
         <0.6 when you're guessing. The pipeline rejects below 0.6.

    4. Output ONLY valid JSON matching the schema. No markdown fences, no \
       commentary, no explanation. The exact schema:

       { "isBookPage": boolean,
         "title": string,
         "authors": [string],
         "isbn13": string | null,
         "lang": string | null,
         "year": number | null,
         "confidence": number }

    Be conservative. A wrong identification sends the wrong book to the \
    user's reader.
    """

    public static func identify(_ input: Input, apiKey: String? = nil) async throws -> Identified {
        let key = apiKey ?? SettingsStore.shared.anthropicAPIKey()
        guard let key, !key.isEmpty else { throw Error.missingAPIKey }

        let snippet = String(input.snippet.prefix(4000))
        let userPrompt = """
        URL: \(input.url)
        Page title: \(input.title ?? "(unknown)")
        Page lang attribute: \(input.lang ?? "(unknown)")

        Page text snippet (first 4 KB, may be truncated):

        \(snippet)
        """

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.httpError(-1, "no response")
        }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Error.httpError(http.statusCode, text)
        }

        let envelope = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let textBlock = envelope.content.first(where: { $0.type == "text" })?.text else {
            throw Error.decodeError("no text block in response")
        }
        let trimmed = JSONHelpers.stripJSONFence(textBlock)
        guard let payloadData = trimmed.data(using: .utf8) else {
            throw Error.decodeError("payload not utf-8")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw Error.decodeError("model output was not the expected JSON shape: \(error.localizedDescription)\n--\n\(trimmed.prefix(400))")
        }

        return Identified(
            isBookPage: payload.isBookPage,
            title: payload.title,
            authors: payload.authors,
            isbn13: payload.isbn13?.replacingOccurrences(of: "[^0-9X]", with: "", options: .regularExpression).nonEmpty,
            lang: payload.lang?.nonEmpty,
            year: payload.year,
            confidence: payload.confidence
        )
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct Payload: Decodable {
        let isBookPage: Bool
        let title: String
        let authors: [String]
        let isbn13: String?
        let lang: String?
        let year: Int?
        let confidence: Double
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

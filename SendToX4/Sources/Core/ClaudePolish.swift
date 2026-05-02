import Foundation

/// LLM polish stage. Strict contract:
///
///   - Body text is NEVER rewritten, paraphrased, or summarized. The model
///     may only delete obvious chrome (Subscribe / Share / footer cruft) and
///     normalize title/author/chapter boundaries.
///   - The output is validated: combined polished body word count must be
///     >= 95% of input. If not, the unpolished sanitized HTML is used.
///   - The big system prompt is sent under `cache_control: ephemeral` so we
///     pay for it once per ~5 minutes and get >90% cost reduction afterwards.
public enum ClaudePolish {

    public struct Polished: Sendable {
        public var title: String
        public var author: String?
        public var chapters: [Chapter]
        public var fellBackToUnpolished: Bool
        public var inputWordCount: Int
        public var outputWordCount: Int
        public var cacheCreationTokens: Int?
        public var cacheReadTokens: Int?

        public struct Chapter: Sendable {
            public var heading: String
            public var html: String
        }
    }

    public struct Input: Sendable {
        public var title: String
        public var byline: String?
        public var siteName: String?
        public var sourceURL: String?
        public var bodyXHTML: String
        public var inputWordCount: Int

        public init(title: String, byline: String?, siteName: String?, sourceURL: String?, bodyXHTML: String, inputWordCount: Int) {
            self.title = title
            self.byline = byline
            self.siteName = siteName
            self.sourceURL = sourceURL
            self.bodyXHTML = bodyXHTML
            self.inputWordCount = inputWordCount
        }
    }

    public enum Error: Swift.Error {
        case missingAPIKey
        case httpError(Int, String)
        case decodeError(String)
    }

    public static let model = "claude-sonnet-4-6"

    public static let systemPrompt = """
    You are the "polish" stage in a pipeline that converts saved web articles \
    into EPUB books for a small e-ink reader (Xteink X4, 4.3" display).

    Your job is to clean up captured article HTML *without ever rewriting the \
    body text*. The goal is a presentable book of the original author's words.

    HARD RULES — violating any of these is a critical failure:

    1. NEVER paraphrase, rewrite, summarize, translate, or "improve" the \
       article's prose. Body text passes through verbatim — every word, in \
       the original order. You are an editor working with a red pen, not a \
       co-author.

    2. You may DELETE content, but only when it is obvious site chrome that \
       does not belong in a book. Examples that ARE safe to delete:
         - "Subscribe to my newsletter" / "Share this post" / "Comments (12)"
         - related-posts widgets, author bio boxes that are not the article \
           itself, "Read next" lists, social-icon rows, paywall teasers
         - editor's note boxes that are clearly site chrome (NOT the author's \
           own footnotes or addenda)
       If unsure whether something is the author's content, KEEP IT.

    3. You may RESTRUCTURE only by:
         - splitting the body into chapters when the source clearly has h1/h2 \
           chapter boundaries (long essays, multi-part posts, books)
         - normalizing the title (strip "by Author Name" / "— Site Name" / \
           "[draft]" suffixes)
         - normalizing the author/byline
         - merging orphaned footnote markers with their referents
         - converting inline footnote refs into anchor links to a "Notes" \
           section at the end if the source has clearly separated notes

       For most short essays the answer is ONE chapter containing the entire \
       body unchanged.

    4. You must preserve all `<img>` tags exactly, including their `src` \
       attribute (which points to local placeholders the pipeline will \
       resolve). You must preserve all link text inside <a> tags.

    5. Output ONLY valid JSON matching this schema, with no prose, no markdown \
       fences, no commentary:

       {
         "title": string,                     // cleaned title
         "author": string | null,             // cleaned author/byline, null if unknown
         "chapters": [
           {
             "heading": string,                // chapter title; "" for an untitled single chapter
             "html": string                    // XHTML body fragment, no <html> or <body> wrapper
           }
         ]
       }

       The `html` strings must be well-formed XHTML fragments (self-closing \
       void elements like <br/>, <hr/>, <img .../>, all attributes quoted, \
       ampersands escaped). Do not include <head>, <body>, scripts, styles, \
       or external classnames.

    6. If the input is empty, junk, or not a real article, return:
       { "title": "<original input title>", "author": null, "chapters": \
       [{"heading": "", "html": "<input verbatim>"}] }

    Remember: you are NOT making the article better. You are making it \
    presentable as a book. The author's words are sacred.
    """

    public static func polish(_ input: Input, apiKey: String? = nil) async throws -> Polished {
        let key = apiKey ?? SettingsStore.shared.anthropicAPIKey()
        guard let key, !key.isEmpty else { throw Error.missingAPIKey }

        let userPrompt = """
        Source URL: \(input.sourceURL ?? "(unknown)")
        Site: \(input.siteName ?? "(unknown)")
        Captured title: \(input.title)
        Captured byline: \(input.byline ?? "(unknown)")
        Input body word count: \(input.inputWordCount)

        Body XHTML to polish (do not paraphrase any of this):

        \(input.bodyXHTML)
        """

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
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
        let trimmed = stripJSONFence(textBlock)

        guard let payloadData = trimmed.data(using: .utf8) else {
            throw Error.decodeError("payload not utf-8")
        }
        let payload: PolishPayload
        do {
            payload = try JSONDecoder().decode(PolishPayload.self, from: payloadData)
        } catch {
            throw Error.decodeError("model output was not the expected JSON shape: \(error.localizedDescription)\n--\n\(trimmed.prefix(400))")
        }

        let outputWordCount = payload.chapters.reduce(0) { acc, ch in
            acc + wordCount(in: ch.html)
        }

        // Length guardrail — fall back to unpolished if too much got dropped.
        let ratio = input.inputWordCount > 0 ? Double(outputWordCount) / Double(input.inputWordCount) : 1.0
        if ratio < 0.95 {
            return Polished(
                title: input.title,
                author: input.byline,
                chapters: [.init(heading: "", html: input.bodyXHTML)],
                fellBackToUnpolished: true,
                inputWordCount: input.inputWordCount,
                outputWordCount: input.inputWordCount,
                cacheCreationTokens: envelope.usage?.cache_creation_input_tokens,
                cacheReadTokens: envelope.usage?.cache_read_input_tokens
            )
        }

        return Polished(
            title: payload.title.isEmpty ? input.title : payload.title,
            author: (payload.author?.isEmpty ?? true) ? input.byline : payload.author,
            chapters: payload.chapters.map { .init(heading: $0.heading, html: $0.html) },
            fellBackToUnpolished: false,
            inputWordCount: input.inputWordCount,
            outputWordCount: outputWordCount,
            cacheCreationTokens: envelope.usage?.cache_creation_input_tokens,
            cacheReadTokens: envelope.usage?.cache_read_input_tokens
        )
    }

    // MARK: - Helpers

    private static func stripJSONFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // Strip leading fence (optionally with `json` language tag) and trailing fence.
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    private static func wordCount(in html: String) -> Int {
        // Crude but adequate: strip tags, split on whitespace.
        var inTag = false
        var out = ""
        for ch in html {
            if ch == "<" { inTag = true; out.append(" "); continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    // MARK: - Wire types

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        let usage: Usage?
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
    }

    private struct PolishPayload: Decodable {
        let title: String
        let author: String?
        let chapters: [Chapter]
        struct Chapter: Decodable {
            let heading: String
            let html: String
        }
    }
}

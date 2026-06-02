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
    public static let maxTokens = 32_000
    public static let toolName = "emit_polished_article"

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

    5. Return your result by calling the `\(toolName)` tool exactly once. \
       Do not emit any other text. The tool's `html` strings must be well- \
       formed XHTML fragments (self-closing void elements like <br/>, <hr/>, \
       <img .../>, all attributes quoted, ampersands escaped). Do not include \
       <head>, <body>, scripts, styles, or external classnames.

    6. If the input is empty, junk, or not a real article, call the tool with \
       the original captured title, author=null, and a single chapter whose \
       heading="" and whose html is the input verbatim.

    Remember: you are NOT making the article better. You are making it \
    presentable as a book. The author's words are sacred.
    """

    /// JSON Schema for the forced tool call. Used with `strict: true`, which
    /// activates Anthropic's grammar-constrained sampling — the model is
    /// guaranteed to emit input that matches this schema. Strict mode requires
    /// `additionalProperties: false` on every object schema.
    public static let toolInputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "title": [
                "type": "string",
                "description": "Cleaned article title with site-name / 'by author' suffixes stripped."
            ],
            "author": [
                "type": ["string", "null"],
                "description": "Cleaned author / byline. Null if unknown."
            ],
            "chapters": [
                "type": "array",
                "minItems": 1,
                "description": "Article body split into chapters. Most short essays should be a single chapter — wrap the entire body in one element with heading=\"\".",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "heading": [
                            "type": "string",
                            "description": "Chapter title. Empty string for an untitled single chapter."
                        ],
                        "html": [
                            "type": "string",
                            "description": "Verbatim author body as a well-formed XHTML fragment (no html/body/script/style)."
                        ]
                    ],
                    "required": ["heading", "html"]
                ]
            ]
        ],
        "required": ["title", "author", "chapters"]
    ]

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
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [
                [
                    "type": "text",
                    "text": systemPrompt,
                    "cache_control": ["type": "ephemeral"]
                ]
            ],
            "tools": [
                [
                    "name": toolName,
                    "description": "Emit the cleaned-up article as a structured object. Body text inside each chapter's html field MUST be verbatim from the source — no paraphrasing, rewriting, or summarizing.",
                    "strict": true,
                    "input_schema": toolInputSchema
                ]
            ],
            "tool_choice": [
                "type": "tool",
                "name": toolName
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

        // The response envelope mixes content-block shapes (text vs tool_use),
        // so we parse it loosely with JSONSerialization and pluck the tool_use
        // input object out as raw JSON. That object is then re-encoded and run
        // through our typed PolishPayload decoder.
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.decodeError("response was not a JSON object")
        }
        let stopReason = envelope["stop_reason"] as? String ?? "?"
        let content = envelope["content"] as? [[String: Any]] ?? []
        let usage = envelope["usage"] as? [String: Any]
        let cacheCreationTokens = usage?["cache_creation_input_tokens"] as? Int
        let cacheReadTokens = usage?["cache_read_input_tokens"] as? Int

        guard let toolUse = content.first(where: {
            ($0["type"] as? String) == "tool_use" && ($0["name"] as? String) == toolName
        }) else {
            // Surface anything the model said in lieu of calling the tool —
            // most often this means stop_reason="max_tokens" (truncated mid
            // tool call) or the model emitted text instead of a tool_use.
            let textPreview = (content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String) ?? ""
            throw Error.decodeError("model returned no tool_use block (stop_reason=\(stopReason))\n--\n\(textPreview.prefix(400))")
        }
        guard let inputDict = toolUse["input"] as? [String: Any] else {
            throw Error.decodeError("tool_use block had no input object")
        }

        let payload: PolishPayload
        do {
            let inputData = try JSONSerialization.data(withJSONObject: inputDict)
            payload = try JSONDecoder().decode(PolishPayload.self, from: inputData)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw Error.decodeError("tool_use input data corrupted at \(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw Error.decodeError("tool_use input missing key '\(key.stringValue)' at \(pathString(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw Error.decodeError("tool_use input type mismatch at \(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw Error.decodeError("tool_use input missing value at \(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch {
            throw Error.decodeError("tool_use input decode failed: \(error.localizedDescription)")
        }

        let outputWordCount = payload.chapters.reduce(0) { acc, ch in
            acc + wordCount(in: ch.html)
        }

        // Length guardrail — fall back to unpolished if too much got dropped.
        // Keep the *actual* model word count in `outputWordCount` so the log
        // line reflects what the model emitted, not the unpolished input we
        // ended up shipping.
        let ratio = input.inputWordCount > 0 ? Double(outputWordCount) / Double(input.inputWordCount) : 1.0
        if ratio < 0.95 {
            return Polished(
                title: input.title,
                author: input.byline,
                chapters: [.init(heading: "", html: input.bodyXHTML)],
                fellBackToUnpolished: true,
                inputWordCount: input.inputWordCount,
                outputWordCount: outputWordCount,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens
            )
        }

        return Polished(
            title: payload.title.isEmpty ? input.title : payload.title,
            author: (payload.author?.isEmpty ?? true) ? input.byline : payload.author,
            chapters: payload.chapters.map { .init(heading: $0.heading, html: $0.html) },
            fellBackToUnpolished: false,
            inputWordCount: input.inputWordCount,
            outputWordCount: outputWordCount,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }

    private static func pathString(_ path: [CodingKey]) -> String {
        path.isEmpty ? "<root>" : path.map(\.stringValue).joined(separator: ".")
    }

    // MARK: - Helpers

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

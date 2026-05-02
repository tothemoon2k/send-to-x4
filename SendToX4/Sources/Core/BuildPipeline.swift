import Foundation

/// End-to-end pipeline: pending Capture -> EPUB on disk + queue item set to `.ready`.
///
///   sanitize HTML
///     -> [optional] Claude polish (with prompt caching)
///     -> download + process images (grayscale, dither, resize)
///     -> generate cover
///     -> assemble EPUB
///     -> attach to queue item
public actor BuildPipeline {

    public static let shared = BuildPipeline()

    private let queue: QueueStore
    private let settings: SettingsStore
    public static let maxAttempts = 4

    public init(queue: QueueStore = .shared, settings: SettingsStore = .shared) {
        self.queue = queue
        self.settings = settings
    }

    /// Tries to advance one pending item. Returns true if it processed
    /// something — the caller can loop until false.
    public func processNext() async -> Bool {
        guard let next = await queue.nextNeedsBuild() else { return false }
        try? await queue.setStatus(id: next.id, .building, error: nil)
        do {
            let outcome = try await build(item: next)
            try await queue.update(id: next.id) { item in
                item.epubFilename = outcome.filename
                item.epubSize = outcome.size
                item.status = .ready
                item.lastError = outcome.warning
            }
            log("[build] ready: \(outcome.filename) (\(outcome.size) bytes) for \(next.capture.url)")
        } catch {
            log("[build] failed: \(error) for \(next.capture.url)")
            try? await queue.incrementAttempts(id: next.id)
            let attempts = (await queue.find(id: next.id))?.attempts ?? next.attempts + 1
            if attempts >= Self.maxAttempts {
                try? await queue.setStatus(id: next.id, .failed, error: "\(error)")
            } else {
                // Send back to pending for retry next tick.
                try? await queue.setStatus(id: next.id, .pending, error: "\(error)")
            }
        }
        return true
    }

    public struct BuildOutcome {
        public var filename: String
        public var size: Int
        public var warning: String?
    }

    private func build(item: QueueItem) async throws -> BuildOutcome {
        let capture = item.capture
        let baseURL = URL(string: capture.url)

        // 1. Sanitize.
        let rawHTML = capture.content ?? ""
        let sanitized = try HTMLSanitizer.sanitize(rawHTML, baseURL: baseURL)

        // 2. Polish (optional).
        var polishedTitle = capture.title?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? capture.url
        var polishedAuthor = capture.byline?.trimmingCharacters(in: .whitespaces).nonEmpty
        var polishedChapters: [(heading: String, html: String)] = [
            (capture.title ?? "", sanitized.bodyXHTML)
        ]
        var fellBack = false

        let snapshot = settings.snapshot
        if snapshot.llmEnabled, settings.anthropicAPIKey() != nil {
            do {
                let polished = try await ClaudePolish.polish(.init(
                    title: capture.title ?? "",
                    byline: capture.byline,
                    siteName: capture.siteName,
                    sourceURL: capture.url,
                    bodyXHTML: sanitized.bodyXHTML,
                    inputWordCount: sanitized.wordCount
                ))
                polishedTitle = polished.title.nonEmpty ?? polishedTitle
                polishedAuthor = polished.author?.nonEmpty ?? polishedAuthor
                polishedChapters = polished.chapters.map { ($0.heading, $0.html) }
                fellBack = polished.fellBackToUnpolished
                log("[polish] \(fellBack ? "fell back (length guardrail)" : "ok")  in=\(polished.inputWordCount) out=\(polished.outputWordCount) cacheRead=\(polished.cacheReadTokens ?? 0) cacheCreate=\(polished.cacheCreationTokens ?? 0)")
            } catch ClaudePolish.Error.missingAPIKey {
                log("[polish] skipped — no API key")
            } catch {
                log("[polish] error, falling back to unpolished: \(error)")
                fellBack = true
            }
        }

        // 3. Process images. We download then dither each into PNG.
        var images: [EpubWriter.Image] = []
        var imgFilenameMap: [String: String] = [:]   // local id ("img-001") -> final filename ("img-001.png")
        for ref in sanitized.images {
            do {
                let raw = try await ImageProcessor.download(ref.sourceURL)
                let processed = try ImageProcessor.process(raw, sourceURL: ref.sourceURL)
                let finalName = "\(ref.id).png"
                imgFilenameMap[ref.id] = finalName
                images.append(.init(
                    id: ref.id,
                    filename: finalName,
                    mediaType: "image/png",
                    data: processed.pngData
                ))
            } catch {
                log("[image] \(ref.sourceURL.absoluteString) → \(error). Dropping.")
                imgFilenameMap[ref.id] = nil
            }
        }

        // Rewrite image refs in chapter HTML to final filenames; strip <img> for failures.
        let rewrittenChapters: [EpubWriter.Chapter] = polishedChapters.enumerated().map { (i, ch) in
            var html = ch.html
            for ref in sanitized.images {
                let placeholder = ref.id
                if let final = imgFilenameMap[ref.id] {
                    html = html.replacingOccurrences(
                        of: "src=\"\(placeholder)\"",
                        with: "src=\"\(final)\""
                    )
                } else {
                    // Remove the <img> tag entirely if we couldn't fetch it.
                    let pattern = "<img[^>]*src=\"\(NSRegularExpression.escapedPattern(for: placeholder))\"[^>]*/?>"
                    html = html.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                }
            }
            let heading = ch.heading.nonEmpty ?? (i == 0 ? polishedTitle : "Chapter \(i + 1)")
            return EpubWriter.Chapter(title: heading, bodyHTML: html)
        }

        // 4. Generate cover.
        let cover = CoverGenerator.makePNG(.init(
            title: polishedTitle,
            author: polishedAuthor,
            source: capture.siteName ?? URL(string: capture.url)?.host
        ))

        // 5. Assemble EPUB.
        let lang = capture.lang?.nonEmpty ?? "en"
        var publishedDate: Date? = nil
        if let pub = capture.publishedTime {
            publishedDate = ISO8601DateFormatter.parsing.date(from: pub)
        }
        let epubInput = EpubWriter.Input(
            identifier: "urn:send-to-x4:\(item.id)",
            title: polishedTitle,
            author: polishedAuthor,
            sourceURL: capture.url,
            sourceName: capture.siteName,
            lang: lang,
            publishedTime: publishedDate,
            chapters: rewrittenChapters,
            coverPNG: cover,
            images: images
        )
        let data = try EpubWriter.write(epubInput)

        // 6. Persist.
        let filename = epubFilename(for: item, title: polishedTitle)
        let outURL = AppPaths.queueDir.appendingPathComponent(filename)
        try data.write(to: outURL, options: [.atomic])
        return BuildOutcome(filename: filename, size: data.count, warning: fellBack ? "polish fell back" : nil)
    }

    private func epubFilename(for item: QueueItem, title: String) -> String {
        let base = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let trimmed = String(base.prefix(40))
        let stem = trimmed.isEmpty ? "article" : trimmed
        // Short stable suffix for collision-resistance — strip dashes so
        // filenames don't end up with double separators.
        let suffix = item.id
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .prefix(6)
        return "\(stem)-\(suffix).epub"
    }

    private func log(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ISO8601DateFormatter {
    static let parsing: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

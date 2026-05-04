import Foundation

/// End-to-end pipeline: pending Capture -> EPUB on disk + queue item set to `.ready`.
///
///   sanitize HTML
///     -> [optional] Claude polish (with prompt caching)
///     -> download + process images (grayscale, dither, resize)
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
            let attached = try await queue.attachEpub(
                id: next.id,
                filename: outcome.filename,
                data: outcome.data,
                warning: outcome.warning
            )
            if attached {
                log("[build] ready: \(outcome.filename) (\(outcome.data.count) bytes) for \(next.capture.url)")
            } else {
                // Item was evicted (e.g. same-URL re-enqueue) while the build
                // was in flight; the EPUB is dropped rather than orphaned.
                log("[build] dropped stale build for \(next.capture.url) — item evicted")
            }
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
        public var data: Data
        public var warning: String?
    }

    public enum BuildError: Swift.Error, CustomStringConvertible {
        case notABook(reason: String)
        case noCandidates(query: String)
        case missingAnnasArchiveKey

        public var description: String {
            switch self {
            case .notABook(let reason): return "Page is not a book page (\(reason))"
            case .noCandidates(let q):  return "No download candidates from Anna's Archive for query: \(q)"
            case .missingAnnasArchiveKey: return "Anna's Archive member key is not set in Settings."
            }
        }
    }

    private func build(item: QueueItem) async throws -> BuildOutcome {
        switch item.capture.kind {
        case .article: return try await buildArticle(item: item)
        case .book:    return try await buildBook(item: item)
        }
    }

    private func buildArticle(item: QueueItem) async throws -> BuildOutcome {
        let capture = item.capture
        let baseURL = URL(string: capture.url)
        let snapshot = settings.snapshot

        // 0. Auto-detect: if the user hit "Send to X4" on a book detail page
        //    (Amazon /dp/, Goodreads /book/show/, Project Gutenberg /ebooks/,
        //    a publisher catalog page, …) we'd otherwise produce an EPUB of
        //    the page chrome. Ask the model first; on a high-confidence yes,
        //    persist the kind change and reroute to the book pipeline.
        //    Skipped without a Claude key — no way to classify, and the
        //    article path stays useful for users without an LLM key.
        if snapshot.llmEnabled, settings.anthropicAPIKey() != nil {
            if let identified = await detectBookPage(capture), identified.confidence >= 0.75 {
                log("[build] auto-routing book page (\(capture.url)): \(identified.title) conf=\(String(format: "%.2f", identified.confidence))")
                try? await queue.update(id: item.id) { $0.capture.kind = .book }
                var rerouted = item
                rerouted.capture.kind = .book
                return try await buildBook(item: rerouted, prefetched: identified)
            }
        }

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

        // 4. Assemble EPUB. No cover page — articles open straight into
        //    the body. The TOC (nav) is included in the spine only when
        //    there's more than one chapter; see EpubWriter.
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
            coverPNG: nil,
            images: images
        )
        let data = try EpubWriter.write(epubInput)

        // The EPUB is written to disk by QueueStore.attachEpub atomically with
        // the manifest update — keeps the disk and the manifest in sync.
        let filename = await epubFilename(for: item, title: polishedTitle)
        return BuildOutcome(filename: filename, data: data, warning: fellBack ? "polish fell back" : nil)
    }

    private func epubFilename(for item: QueueItem, title: String) async -> String {
        await epubFilename(for: item, title: title, fallbackStem: "article")
    }

    private func epubFilename(for item: QueueItem, title: String, fallbackStem: String) async -> String {
        let base = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let trimmed = String(base.prefix(40))
        let stem = trimmed.isEmpty ? fallbackStem : trimmed
        // Disambiguate only on actual collision against other queue items.
        // The current item is excluded so retries reuse their own filename
        // rather than racing themselves to "-2".
        let used: Set<String> = Set(await queue.all().compactMap { other in
            other.id == item.id ? nil : other.epubFilename
        })
        let primary = "\(stem).epub"
        if !used.contains(primary) { return primary }
        for n in 2...99 {
            let candidate = "\(stem)-\(n).epub"
            if !used.contains(candidate) { return candidate }
        }
        // Pathological: 99 same-titled items in flight. Fall back to an
        // id-based suffix so we still produce a unique filename.
        let suffix = item.id
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .prefix(6)
        return "\(stem)-\(suffix).epub"
    }

    // MARK: - Book branch

    /// Best-effort "is this URL really a book detail page?" classifier used
    /// by the article path to auto-route. Returns nil on any failure (missing
    /// key, model error, empty snippet) — callers fall through to the article
    /// path so a flaky classifier never blocks normal captures.
    /// Fetches a cover from og:image / Open Library and runs it through the
    /// X4-tuned image pipeline (grayscale + Atkinson dither + fit to 480×800).
    /// Returns nil if no cover could be sourced or the processing failed —
    /// the caller falls through to "no cover" silently rather than failing
    /// the whole build.
    private func fetchAndProcessCover(ogImage: String?, isbn13: String?) async -> Data? {
        guard let raw = await BookCoverFetcher.fetch(ogImageURL: ogImage, isbn13: isbn13) else {
            return nil
        }
        do {
            return try ImageProcessor.process(raw).pngData
        } catch {
            log("[book] cover process failed: \(error)")
            return nil
        }
    }

    private func detectBookPage(_ capture: Capture) async -> BookIdentifier.Identified? {
        let snippet = capture.textContent?.nonEmpty
            ?? capture.excerpt?.nonEmpty
            ?? String((capture.content ?? "").prefix(8000))
        guard !snippet.isEmpty else { return nil }
        do {
            let id = try await BookIdentifier.identify(.init(
                url: capture.url,
                title: capture.title,
                lang: capture.lang,
                snippet: snippet
            ))
            return id.isBookPage ? id : nil
        } catch {
            log("[detect-book] skipped: \(error)")
            return nil
        }
    }

    private func buildBook(item: QueueItem, prefetched: BookIdentifier.Identified? = nil) async throws -> BuildOutcome {
        let cap = item.capture
        log("[book] identify: \(cap.url)")

        // 1. Identify the book (skip if the article path already did it).
        let identified: BookIdentifier.Identified
        if let prefetched {
            identified = prefetched
        } else {
            do {
                identified = try await BookIdentifier.identify(.init(
                    url: cap.url,
                    title: cap.title,
                    lang: cap.lang,
                    snippet: cap.textContent ?? cap.excerpt ?? ""
                ))
            } catch BookIdentifier.Error.missingAPIKey {
                throw BuildError.notABook(reason: "Anthropic API key not set — needed to identify the book")
            }
        }
        guard identified.isBookPage else {
            throw BuildError.notABook(reason: "model said this isn't a single-book page")
        }
        guard identified.confidence >= 0.6 else {
            throw BuildError.notABook(reason: "low confidence \(String(format: "%.2f", identified.confidence))")
        }
        log("[book] identified: \(identified.title) — \(identified.authors.joined(separator: ", "))  conf=\(String(format: "%.2f", identified.confidence))")

        // 2. Resolve the active Anna's Archive mirror.
        let mirror = try await AnnasArchive.shared.resolveMirror()
        log("[book] mirror: \(mirror.host ?? "?")")

        // 3. Search candidates.
        let query = ([identified.title] + identified.authors.prefix(1))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let candidates = try await AnnasArchive.shared.search(query: query, preferredLang: identified.lang)
        guard let best = AnnasArchive.pickBest(candidates, preferredLang: identified.lang) else {
            throw BuildError.noCandidates(query: query)
        }
        log("[book] picked: format=\(best.format) size=\(best.sizeBytes ?? 0)B lang=\(best.lang ?? "?") md5=\(best.md5)")

        // 4. Resolve fast download URL (member key required).
        guard let key = settings.annasArchiveAPIKey(), !key.isEmpty else {
            throw BuildError.missingAnnasArchiveKey
        }
        let downloadURL = try await AnnasArchive.shared.fastDownloadURL(md5: best.md5, key: key)

        // 5. Download bytes.
        let raw = try await AnnasArchive.shared.downloadFile(downloadURL)
        log("[book] downloaded \(raw.count) bytes from \(downloadURL.host ?? "?")")

        // 6. Source a cover image. Done in parallel with the download in
        //    spirit — we await it here, but the og:image is usually a tiny
        //    JPEG and Open Library is fast.
        let processedCover = await fetchAndProcessCover(
            ogImage: cap.ogImage,
            isbn13: identified.isbn13
        )
        if processedCover != nil {
            log("[book] cover sourced (\(processedCover!.count) bytes after dither)")
        } else {
            log("[book] no cover sourced — pass-through EPUBs will keep their existing cover, others will ship without one")
        }

        // 7. Convert if needed; pass the cover so converted paths embed it
        //    natively and pass-through EPUBs get one injected only when missing.
        let hint = BookConverter.Hint(
            title: identified.title,
            authors: identified.authors,
            lang: identified.lang ?? cap.lang,
            sourceURL: cap.url,
            identifier: "urn:send-to-x4:\(item.id)"
        )
        let epubData = try await BookConverter.toEPUB(raw, format: best.format, hint: hint, coverPNG: processedCover)
        log("[book] EPUB ready: \(epubData.count) bytes")

        let filename = await epubFilename(for: item, title: identified.title, fallbackStem: "book")
        return BuildOutcome(filename: filename, data: epubData, warning: nil)
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

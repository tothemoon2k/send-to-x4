import Foundation

public enum CaptureKind: String, Codable, Sendable {
    case article
    case book
}

/// One thing captured from the browser, ready to be turned into an EPUB.
/// Discriminated by `kind`: an `.article` is sanitized + polished + EPUB-built
/// here; a `.book` triggers identification → Anna's Archive lookup → download
/// → optional conversion. Article fields are still used for books to pass the
/// LLM context (page title, page text snippet) for identification.
public struct Capture: Codable, Sendable, Identifiable {
    public var id: String
    public var kind: CaptureKind
    public var url: String
    public var title: String?
    public var byline: String?
    public var siteName: String?
    public var lang: String?
    public var content: String?
    public var textContent: String?
    public var excerpt: String?
    public var publishedTime: String?
    public var ogImage: String?
    public var capturedAt: Date
    public var source: String? // "page" | "link" | "selection" | "book"
    public var needsServerFetch: Bool?
    public var referrer: String?
    public var length: Int?

    public init(
        id: String = UUID().uuidString,
        kind: CaptureKind = .article,
        url: String,
        title: String? = nil,
        byline: String? = nil,
        siteName: String? = nil,
        lang: String? = nil,
        content: String? = nil,
        textContent: String? = nil,
        excerpt: String? = nil,
        publishedTime: String? = nil,
        ogImage: String? = nil,
        capturedAt: Date = Date(),
        source: String? = nil,
        needsServerFetch: Bool? = nil,
        referrer: String? = nil,
        length: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.byline = byline
        self.siteName = siteName
        self.lang = lang
        self.content = content
        self.textContent = textContent
        self.excerpt = excerpt
        self.publishedTime = publishedTime
        self.ogImage = ogImage
        self.capturedAt = capturedAt
        self.source = source
        self.needsServerFetch = needsServerFetch
        self.referrer = referrer
        self.length = length
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, url, title, byline, siteName, lang, content, textContent
        case excerpt, publishedTime, ogImage, capturedAt, source
        case needsServerFetch, referrer, length
    }

    // Browser extensions don't generate an id — server mints one when absent.
    // `kind` defaults to .article so older clients (that don't send it) keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.kind = try c.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .article
        self.url = try c.decode(String.self, forKey: .url)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.byline = try c.decodeIfPresent(String.self, forKey: .byline)
        self.siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        self.lang = try c.decodeIfPresent(String.self, forKey: .lang)
        self.content = try c.decodeIfPresent(String.self, forKey: .content)
        self.textContent = try c.decodeIfPresent(String.self, forKey: .textContent)
        self.excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        self.publishedTime = try c.decodeIfPresent(String.self, forKey: .publishedTime)
        self.ogImage = try c.decodeIfPresent(String.self, forKey: .ogImage)
        self.capturedAt = try c.decodeIfPresent(Date.self, forKey: .capturedAt) ?? Date()
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.needsServerFetch = try c.decodeIfPresent(Bool.self, forKey: .needsServerFetch)
        self.referrer = try c.decodeIfPresent(String.self, forKey: .referrer)
        self.length = try c.decodeIfPresent(Int.self, forKey: .length)
    }
}

public enum QueueItemStatus: String, Codable, Sendable {
    case pending          // captured, awaiting build
    case building         // running through pipeline
    case ready            // EPUB on disk, awaiting upload
    case uploading
    case uploaded
    case failed
}

public struct QueueItem: Codable, Sendable, Identifiable {
    public var id: String
    public var capture: Capture
    public var status: QueueItemStatus
    public var epubFilename: String?
    public var epubSize: Int?
    public var lastError: String?
    public var attempts: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(capture: Capture) {
        self.id = capture.id
        self.capture = capture
        self.status = .pending
        self.epubFilename = nil
        self.epubSize = nil
        self.lastError = nil
        self.attempts = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

import Foundation

/// One article captured from the browser, ready to be turned into an EPUB.
public struct Capture: Codable, Sendable, Identifiable {
    public var id: String
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
    public var source: String? // "page" | "link" | "selection"
    public var needsServerFetch: Bool?
    public var referrer: String?
    public var length: Int?

    public init(
        id: String = UUID().uuidString,
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

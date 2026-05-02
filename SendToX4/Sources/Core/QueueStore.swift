import Foundation

/// Disk-backed queue. The on-disk layout:
///
///   ~/Library/Application Support/SendToX4/
///     queue.json                    -> manifest of QueueItem
///     queue/<id>.epub               -> built EPUBs awaiting upload
///     queue/<id>.capture.json       -> raw capture for retries
///
/// Survives crashes, restarts, sleep/wake. The manifest is rewritten atomically.
public actor QueueStore {
    public static let shared = QueueStore()

    private var items: [QueueItem] = []
    private var loaded = false

    public init() {}

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        let url = AppPaths.manifestURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder.iso.decode([QueueItem].self, from: data)
        } catch {
            // Corrupt manifest is non-fatal; archive and start fresh.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            items = []
        }
    }

    private func persist() throws {
        let data = try JSONEncoder.pretty.encode(items)
        try data.write(to: AppPaths.manifestURL, options: [.atomic])
    }

    // MARK: - Reads

    public func all() -> [QueueItem] { ensureLoaded(); return items }

    public func count() -> Int { ensureLoaded(); return items.count }

    public func pendingCount() -> Int {
        ensureLoaded()
        return items.filter { $0.status != .uploaded && $0.status != .failed }.count
    }

    public func find(id: String) -> QueueItem? {
        ensureLoaded()
        return items.first(where: { $0.id == id })
    }

    public func nextReadyForUpload() -> [QueueItem] {
        ensureLoaded()
        return items.filter { $0.status == .ready || $0.status == .uploading }
    }

    public func nextNeedsBuild() -> QueueItem? {
        ensureLoaded()
        return items.first(where: { $0.status == .pending })
    }

    // MARK: - Writes

    @discardableResult
    public func enqueue(_ capture: Capture) throws -> QueueItem {
        ensureLoaded()
        // Idempotency: if same URL is already pending/ready, replace it.
        items.removeAll { existing in
            existing.capture.url == capture.url &&
            (existing.status == .pending || existing.status == .ready || existing.status == .building)
        }
        let item = QueueItem(capture: capture)
        items.append(item)
        // Persist the raw capture for retry/debug.
        let captureURL = AppPaths.queueDir.appendingPathComponent("\(item.id).capture.json")
        let captureData = try JSONEncoder.pretty.encode(capture)
        try? captureData.write(to: captureURL, options: [.atomic])
        try persist()
        return item
    }

    public func update(id: String, _ mutate: (inout QueueItem) -> Void) throws {
        ensureLoaded()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
        items[idx].updatedAt = Date()
        try persist()
    }

    public func setStatus(id: String, _ status: QueueItemStatus, error: String? = nil) throws {
        try update(id: id) { item in
            item.status = status
            if let error { item.lastError = error }
        }
    }

    public func attachEpub(id: String, filename: String, size: Int) throws {
        try update(id: id) { item in
            item.epubFilename = filename
            item.epubSize = size
            item.status = .ready
        }
    }

    public func incrementAttempts(id: String) throws {
        try update(id: id) { item in
            item.attempts += 1
        }
    }

    public func remove(id: String) throws {
        ensureLoaded()
        items.removeAll { $0.id == id }
        // Clean up artifacts.
        let dir = AppPaths.queueDir
        let candidates = [
            dir.appendingPathComponent("\(id).epub"),
            dir.appendingPathComponent("\(id).capture.json")
        ]
        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
        try persist()
    }

    public func purgeUploaded() throws {
        ensureLoaded()
        let toRemove = items.filter { $0.status == .uploaded }
        for item in toRemove {
            try remove(id: item.id)
        }
    }
}

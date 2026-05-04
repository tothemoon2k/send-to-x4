import Foundation

/// Drains queue items with status `.ready` to the X4 device.
/// Idempotent (skips files already on device with matching name+size),
/// retries with bounded backoff, marks uploaded only after a 200 OK
/// followed by a confirming `/api/files` listing.
public actor X4Uploader {

    public static let shared = X4Uploader()

    private let queue: QueueStore
    private let probe: X4Probe

    public init(queue: QueueStore = .shared, probe: X4Probe = X4Probe()) {
        self.queue = queue
        self.probe = probe
    }

    public func attemptOneFlush() async -> FlushResult {
        // Find ready items first; no point probing if there's nothing to send.
        let ready = await queue.nextReadyForUpload()
        guard !ready.isEmpty else {
            return FlushResult(reachable: false, sent: 0, skipped: 0, failed: 0)
        }
        guard let target = await probe.locate() else {
            return FlushResult(reachable: false, sent: 0, skipped: 0, failed: 0)
        }
        return await flush(to: target.ip, items: ready)
    }

    public struct FlushResult: Sendable {
        public var reachable: Bool
        public var sent: Int
        public var skipped: Int
        public var failed: Int
    }

    private func flush(to ip: String, items: [QueueItem]) async -> FlushResult {
        var sent = 0
        var skipped = 0
        var failed = 0

        // Group ready items by destination directory so we make one mkdir +
        // one /api/files probe per directory regardless of how many items
        // are in flight.
        var groups: [String: [QueueItem]] = [:]
        var order: [String] = []
        for item in items {
            let dir = destinationPath(for: item)
            if groups[dir] == nil { order.append(dir) }
            groups[dir, default: []].append(item)
        }

        // Cache per-directory file listings across this flush.
        var listingCache: [String: [String: Int]] = [:]
        var ensuredDirs: Set<String> = []

        outer: for path in order {
            guard let group = groups[path] else { continue }

            if !ensuredDirs.contains(path) {
                await ensureDirectoryExists(ip: ip, path: path)
                ensuredDirs.insert(path)
            }

            let existing: [String: Int]
            if let cached = listingCache[path] {
                existing = cached
            } else {
                existing = await fetchListing(ip: ip, path: path)
                listingCache[path] = existing
            }

            for item in group {
                guard let filename = item.epubFilename else { continue }
                let url = AppPaths.queueDir.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url) else {
                    try? await queue.setStatus(id: item.id, .failed, error: "EPUB missing on disk")
                    failed += 1
                    continue
                }

                // Idempotency: same name + same size at the same path → skip.
                if let existingSize = existing[filename], existingSize == data.count {
                    try? await queue.setStatus(id: item.id, .uploaded)
                    skipped += 1
                    continue
                }

                try? await queue.setStatus(id: item.id, .uploading)
                try? await queue.incrementAttempts(id: item.id)

                do {
                    let uploadPath = path == "/" ? nil : path
                    try await X4Client.upload(ip: ip, filename: filename, data: data, path: uploadPath)
                    // Confirm with a list to make sure it landed at the same path.
                    let after = try await X4Client.listFiles(ip: ip, path: path)
                    if after.contains(where: { $0.name == filename && ($0.size ?? -1) == data.count }) {
                        try? await queue.setStatus(id: item.id, .uploaded)
                        sent += 1
                    } else {
                        try? await queue.setStatus(id: item.id, .ready,
                            error: "Upload returned 200 but file did not appear in listing")
                        failed += 1
                    }
                } catch {
                    try? await queue.setStatus(id: item.id, .ready, error: "\(error)")
                    failed += 1
                    // Stop the loop on the first failure — likely the device dropped off WiFi.
                    break outer
                }
            }
        }

        return FlushResult(reachable: true, sent: sent, skipped: skipped, failed: failed)
    }

    /// Where on the device this item should land. Articles/essays go into
    /// `/essays`; books stay at root.
    private func destinationPath(for item: QueueItem) -> String {
        switch item.capture.kind {
        case .article: return "/essays"
        case .book:    return "/"
        }
    }

    private func fetchListing(ip: String, path: String) async -> [String: Int] {
        do {
            let files = try await X4Client.listFiles(ip: ip, path: path)
            var dict: [String: Int] = [:]
            for f in files where !(f.isDirectory == true) {
                if let size = f.size { dict[f.name] = size }
            }
            return dict
        } catch {
            return [:]
        }
    }

    /// Best-effort directory creation. If the directory already exists the
    /// firmware is free to return an error — we tolerate that and let the
    /// upload itself surface any real problem. Only handles single-level
    /// paths like "/essays"; nested paths would need iterative mkdirs.
    private func ensureDirectoryExists(ip: String, path: String) async {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }

        // Skip mkdir if a directory with this name already exists at root.
        if let listing = try? await X4Client.listFiles(ip: ip, path: "/"),
           listing.contains(where: { $0.name == trimmed && $0.isDirectory == true }) {
            return
        }
        _ = try? await X4Client.mkdir(ip: ip, name: trimmed, path: nil)
    }
}

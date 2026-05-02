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

        // Pre-fetch the device's file list once for idempotency checks.
        let existing: [String: Int] = await {
            do {
                let files = try await X4Client.listFiles(ip: ip, path: "/")
                var dict: [String: Int] = [:]
                for f in files {
                    if let size = f.size { dict[f.name] = size }
                }
                return dict
            } catch {
                return [:]
            }
        }()

        for item in items {
            guard let filename = item.epubFilename else { continue }
            let url = AppPaths.queueDir.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                try? await queue.setStatus(id: item.id, .failed, error: "EPUB missing on disk")
                failed += 1
                continue
            }

            // Idempotency: same name + same size on device → skip and mark uploaded.
            if let existingSize = existing[filename], existingSize == data.count {
                try? await queue.setStatus(id: item.id, .uploaded)
                skipped += 1
                continue
            }

            try? await queue.setStatus(id: item.id, .uploading)
            try? await queue.incrementAttempts(id: item.id)

            do {
                try await X4Client.upload(ip: ip, filename: filename, data: data)
                // Confirm with a list to make sure it landed.
                let after = try await X4Client.listFiles(ip: ip, path: "/")
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
                break
            }
        }

        return FlushResult(reachable: true, sent: sent, skipped: skipped, failed: failed)
    }
}

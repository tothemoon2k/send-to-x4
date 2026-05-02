import Foundation
import SendToX4Core

// Headless `sendtox4d` daemon. Owns the HTTP server, the queue, the build
// pipeline (capture -> sanitize -> polish -> EPUB), and the X4 probe / upload
// loop. Persists everything to ~/Library/Application Support/SendToX4.

let port: UInt16 = {
    if let env = ProcessInfo.processInfo.environment["SENDTOX4_PORT"], let p = UInt16(env) { return p }
    return 47821
}()

let server = HTTPServer(port: port)

// MARK: - Routes

server.route("GET", "/healthz") { _ in
    .text("ok")
}

server.route("GET", "/status") { _ in
    let queue = await QueueStore.shared.all()
    let summary = StatusResponse(
        queueLength: queue.filter { $0.status != .uploaded && $0.status != .failed }.count,
        x4Reachable: lastReachable,
        lastUploadAt: queue.compactMap { $0.status == .uploaded ? $0.updatedAt : nil }.max(),
        items: queue.map {
            .init(
                id: $0.id,
                title: $0.capture.title ?? $0.capture.url,
                status: $0.status,
                attempts: $0.attempts,
                error: $0.lastError
            )
        }
    )
    return .json(summary)
}

server.route("POST", "/capture") { req in
    do {
        let capture = try JSONDecoder.iso.decode(Capture.self, from: req.body)
        let item = try await QueueStore.shared.enqueue(capture)
        signalWork()
        return .json(CaptureAck(ok: true, id: item.id))
    } catch {
        return .error(400, "Invalid capture: \(error.localizedDescription)")
    }
}

server.route("POST", "/flush") { _ in
    signalWork()
    let n = await QueueStore.shared.pendingCount()
    return .json(FlushAck(ok: true, queued: n))
}

server.route("POST", "/settings/x4-ip") { req in
    struct Req: Decodable { let ip: String }
    let r = try JSONDecoder().decode(Req.self, from: req.body)
    try SettingsStore.shared.update { $0.lastKnownX4IP = r.ip.trimmingCharacters(in: .whitespaces) }
    return .json(["ok": true])
}

server.route("POST", "/settings/api-key") { req in
    struct Req: Decodable { let key: String }
    let r = try JSONDecoder().decode(Req.self, from: req.body)
    try SettingsStore.shared.setAnthropicAPIKey(r.key)
    return .json(["ok": true])
}

// MARK: - Worker loop

// Fires when there's potential work (capture arrived, /flush hit, tick).
let workSignal = AsyncStream<Void>.makeStream()
nonisolated(unsafe) var lastReachable: Bool = false

func signalWork() {
    workSignal.continuation.yield(())
}

Task {
    // Build worker: drains pending items as fast as it can.
    for await _ in workSignal.stream {
        while await BuildPipeline.shared.processNext() {
            // Loop until queue has nothing pending.
        }
        // After build, try to upload anything ready.
        let result = await X4Uploader.shared.attemptOneFlush()
        lastReachable = result.reachable
        if result.reachable && (result.sent > 0 || result.skipped > 0 || result.failed > 0) {
            fputs("[daemon] flushed: sent=\(result.sent) skipped=\(result.skipped) failed=\(result.failed)\n", stderr)
        }
    }
}

// Probe ticker: independent of capture events, periodically pokes the X4.
Task {
    while true {
        let interval = SettingsStore.shared.snapshot.probeIntervalSeconds
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        signalWork()
    }
}

// MARK: - Boot

do {
    try server.start()
} catch {
    fputs("[daemon] failed to start: \(error)\n", stderr)
    exit(1)
}

fputs("[daemon] sendtox4d started — \(AppPaths.supportDir.path)\n", stderr)
fputs("[daemon] queue.json: \(AppPaths.manifestURL.path)\n", stderr)

// Trigger an initial pass so any leftover items get processed.
signalWork()

RunLoop.main.run()

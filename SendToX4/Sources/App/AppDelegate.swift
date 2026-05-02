import AppKit
import SwiftUI
import Combine
import SendToX4Core

/// Boots the embedded HTTP server, queue worker, and X4 probe loop when the
/// menubar app launches. Everything the standalone `sendtox4d` daemon does,
/// but in-process so the user has one app to install.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var server: HTTPServer?
    private var workTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?

    private let workSignal = AsyncStream<Void>.makeStream()

    func applicationDidFinishLaunching(_ notification: Notification) {
        startHTTPServer()
        startWorker()
        startTicker()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        workTask?.cancel()
        tickerTask?.cancel()
    }

    private func startHTTPServer() {
        let port: UInt16 = {
            if let env = ProcessInfo.processInfo.environment["SENDTOX4_PORT"], let p = UInt16(env) { return p }
            return 47821
        }()
        let server = HTTPServer(port: port)
        let signal = workSignal

        server.route("GET", "/healthz") { _ in .text("ok") }

        server.route("GET", "/status") { _ in
            await Self.statusResponse()
        }

        server.route("POST", "/capture") { req in
            do {
                let capture = try JSONDecoder.iso.decode(Capture.self, from: req.body)
                let item = try await QueueStore.shared.enqueue(capture)
                signal.continuation.yield(())
                return .json(["ok": true, "id": item.id])
            } catch {
                return .error(400, "Invalid capture: \(error.localizedDescription)")
            }
        }

        server.route("POST", "/flush") { _ in
            signal.continuation.yield(())
            let n = await QueueStore.shared.pendingCount()
            return .json(["ok": true, "queued": n])
        }

        server.route("POST", "/settings/x4-ip") { req in
            struct R: Decodable { let ip: String }
            let r = try JSONDecoder().decode(R.self, from: req.body)
            try SettingsStore.shared.update { $0.lastKnownX4IP = r.ip.trimmingCharacters(in: .whitespaces) }
            return .json(["ok": true])
        }

        server.route("POST", "/settings/api-key") { req in
            struct R: Decodable { let key: String }
            let r = try JSONDecoder().decode(R.self, from: req.body)
            try SettingsStore.shared.setAnthropicAPIKey(r.key)
            return .json(["ok": true])
        }

        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("[SendToX4] failed to start daemon HTTP server: %@", String(describing: error))
        }
    }

    private func startWorker() {
        let stream = workSignal.stream
        workTask = Task {
            for await _ in stream {
                // Drain pending builds.
                while await BuildPipeline.shared.processNext() {}
                // Try to upload.
                let result = await X4Uploader.shared.attemptOneFlush()
                await MainActor.run {
                    AppState.shared.applyFlush(result)
                }
            }
        }
    }

    private func startTicker() {
        let signal = workSignal.continuation
        tickerTask = Task {
            // Initial nudge so any leftover queue items are processed.
            signal.yield(())
            while !Task.isCancelled {
                let interval = SettingsStore.shared.snapshot.probeIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                signal.yield(())
            }
        }
    }

    private static func statusResponse() async -> HTTPServer.Response {
        let queue = await QueueStore.shared.all()
        let summary = StatusJSON(
            queueLength: queue.filter { $0.status != .uploaded && $0.status != .failed }.count,
            x4Reachable: AppState.shared.x4Reachable,
            lastUploadAt: queue.compactMap { $0.status == .uploaded ? $0.updatedAt : nil }.max(),
            items: queue.map {
                .init(id: $0.id, title: $0.capture.title ?? $0.capture.url, status: $0.status, attempts: $0.attempts, error: $0.lastError)
            }
        )
        return .json(summary)
    }
}

private struct StatusJSON: Codable {
    var queueLength: Int
    var x4Reachable: Bool
    var lastUploadAt: Date?
    var items: [Item]
    struct Item: Codable {
        var id: String
        var title: String
        var status: QueueItemStatus
        var attempts: Int
        var error: String?
    }
}

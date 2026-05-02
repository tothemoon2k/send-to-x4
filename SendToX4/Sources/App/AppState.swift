import Foundation
import Combine
import SendToX4Core

/// UI-facing state, observable by SwiftUI views. Polls QueueStore on a short
/// timer; keeps the menubar popup live without each view doing its own polling.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var queue: [QueueItem] = []
    @Published var x4Reachable: Bool = false
    @Published var lastFlush: X4Uploader.FlushResult?

    private var timer: Timer?

    private init() {
        startPolling()
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.queue = await QueueStore.shared.all()
            }
        }
    }

    func applyFlush(_ result: X4Uploader.FlushResult) {
        self.lastFlush = result
        self.x4Reachable = result.reachable
    }

    func captureCount(_ status: QueueItemStatus) -> Int {
        queue.filter { $0.status == status }.count
    }

    var pendingItems: [QueueItem] {
        queue.filter { $0.status != .uploaded }
    }
}

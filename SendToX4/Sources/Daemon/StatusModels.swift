import Foundation
import SendToX4Core

struct StatusResponse: Codable {
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

struct CaptureAck: Codable {
    var ok: Bool
    var id: String
}

struct FlushAck: Codable {
    var ok: Bool
    var queued: Int
}

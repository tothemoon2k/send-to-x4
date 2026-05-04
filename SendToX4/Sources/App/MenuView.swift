import SwiftUI
import SendToX4Core

struct MenuView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            queueList
        }
        .padding(0)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.x4Reachable ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(appState.x4Reachable ? "X4 reachable" : "X4 not on network")
                    .font(.system(size: 12))
                Spacer()
                Text("\(appState.pendingItems.count) queued")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let last = appState.lastFlush, last.reachable {
                let text = "Last sync: sent \(last.sent), skipped \(last.skipped)"
                Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var queueList: some View {
        if appState.pendingItems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Queue is empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Right-click an article and choose Send to X4.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(appState.pendingItems) { item in
                        QueueRow(item: item)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        Divider().opacity(0.5)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
    }

}

struct QueueRow: View {
    let item: QueueItem

    private static let thumbSize: CGFloat = 44

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(item.capture.title ?? item.capture.url)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(1)
                }
                if let err = item.lastError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if let raw = item.capture.ogImage, let url = URL(string: raw) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: Self.thumbSize, height: Self.thumbSize)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: item.capture.kind == .book ? "book.closed" : "doc.text")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String? {
        if let b = item.capture.byline?.trimmingCharacters(in: .whitespaces), !b.isEmpty { return b }
        if let s = item.capture.siteName?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        return nil
    }

    private var statusText: String {
        switch item.status {
        case .pending:    return "queued"
        case .building:   return "building"
        case .ready:      return "ready"
        case .uploading:  return "sending"
        case .uploaded:   return "sent"
        case .failed:     return "failed"
        }
    }
}

func postLocal(_ path: String, method: String, body: Data) async throws -> Data {
    let url = URL(string: "http://127.0.0.1:47821\(path)")!
    var req = URLRequest(url: url)
    req.httpMethod = method
    if !body.isEmpty {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
    }
    let (data, _) = try await URLSession.shared.data(for: req)
    return data
}

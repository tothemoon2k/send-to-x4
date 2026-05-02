import SwiftUI
import SendToX4Core

struct MenuView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            queueList
            Divider()
            footer
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

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Send queue now") {
                Task { _ = try? await postLocal("/flush", method: "POST", body: Data()) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))

            Spacer()

            Button("Settings…") {
                openSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14, height: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.capture.title ?? item.capture.url)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                if let site = item.capture.siteName {
                    Text(site)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let err = item.lastError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(statusText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: some View {
        let symbol: String
        let color: Color
        switch item.status {
        case .pending:    symbol = "clock";                color = .secondary
        case .building:   symbol = "gearshape.2";          color = .blue
        case .ready:      symbol = "tray.full";            color = .orange
        case .uploading:  symbol = "arrow.up.circle";      color = .blue
        case .uploaded:   symbol = "checkmark.circle.fill";color = .green
        case .failed:     symbol = "exclamationmark.octagon"; color = .red
        }
        return Image(systemName: symbol).foregroundStyle(color)
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

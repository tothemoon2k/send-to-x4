import Cocoa
import WebKit

/// macOS Share Extension entry point. Lives in the system Share menu shown
/// in Safari (and other apps that vend URLs). Receives the URL of the page
/// being shared, asks the front Safari window for the rendered DOM via
/// AppleScript, and posts a capture to the localhost SendToX4 daemon.
///
/// The Share Extension only sees the URL — by going back to Safari for the
/// live DOM we preserve paywall-aware, authenticated, JS-rendered content
/// rather than re-fetching the URL server-side.
class ShareViewController: NSViewController {

    private let daemonCaptureURL = URL(string: "http://127.0.0.1:47821/capture")!

    override func loadView() {
        // Tiny placeholder — we never present UI; we hand off and dismiss.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await begin() }
    }

    private func begin() async {
        let pageURL = await firstSharedURL()
        guard let pageURL else {
            complete(error: "No URL was shared.")
            return
        }
        do {
            let html = try await readSafariOuterHTML(matching: pageURL)
            try await postCapture(url: pageURL, html: html)
            complete(error: nil)
        } catch {
            complete(error: "\(error.localizedDescription)")
        }
    }

    // MARK: - Pull URL out of the share input

    private func firstSharedURL() async -> URL? {
        let items = self.extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier("public.url") {
                    if let result = try? await provider.loadItem(forTypeIdentifier: "public.url"),
                       let url = result as? URL {
                        return url
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Ask Safari for the page DOM

    enum HandlerError: LocalizedError {
        case appleScriptFailed(String)
        case daemonUnreachable
        case daemonError(Int, String)

        var errorDescription: String? {
            switch self {
            case .appleScriptFailed(let s): return "AppleScript failed: \(s)"
            case .daemonUnreachable: return "Send to X4 helper isn't running."
            case .daemonError(let code, let body): return "Helper rejected capture (\(code)): \(body)"
            }
        }
    }

    private func readSafariOuterHTML(matching url: URL) async throws -> String {
        let script = """
        tell application "Safari"
          set htmlText to ""
          repeat with w in windows
            try
              set t to current tab of w
              set u to URL of t
              if u is "\(url.absoluteString)" then
                set htmlText to (do JavaScript "document.documentElement.outerHTML" in t)
                exit repeat
              end if
            end try
          end repeat
          if htmlText is "" then
            try
              set htmlText to (do JavaScript "document.documentElement.outerHTML" in front document)
            end try
          end if
          return htmlText
        end tell
        """
        return try await runAppleScript(script)
    }

    private func runAppleScript(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(throwing: HandlerError.appleScriptFailed("could not compile"))
                    return
                }
                let result = script.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    cont.resume(throwing: HandlerError.appleScriptFailed("\(error)"))
                    return
                }
                cont.resume(returning: result.stringValue ?? "")
            }
        }
    }

    // MARK: - Post to daemon

    private func postCapture(url: URL, html: String) async throws {
        // Mirror the Capture Codable shape used by the daemon.
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "url": url.absoluteString,
            "title": url.host ?? url.absoluteString,
            "content": html,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "share-sheet",
            // The daemon will re-extract via Readability on the embedded HTML
            // since we send the raw outerHTML, not Readability output.
            "needsServerFetch": false
        ]
        var request = URLRequest(url: daemonCaptureURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HandlerError.daemonUnreachable }
            if !(200..<300).contains(http.statusCode) {
                throw HandlerError.daemonError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        } catch URLError.cannotConnectToHost, URLError.timedOut {
            throw HandlerError.daemonUnreachable
        }
    }

    // MARK: - Lifecycle

    private func complete(error: String?) {
        if let error {
            NSLog("[SendToX4 Share] %@", error)
            // Surface a toast via the sharing service if desired; for now we
            // just log. The user sees the share-sheet dismiss and can check
            // the menu-bar app for status.
        }
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

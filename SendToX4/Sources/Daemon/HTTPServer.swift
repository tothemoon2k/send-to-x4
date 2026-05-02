import Foundation
import Network

/// Minimal HTTP/1.1 server bound to loopback only. Handles one request per
/// connection (Connection: close), JSON in / JSON out. Good enough for the
/// extension <-> daemon contract.
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let path: String
        public let query: [String: String]
        public let headers: [String: String]
        public let body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var contentType: String
        public var body: Data

        public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
            self.status = status
            self.contentType = contentType
            self.body = body
        }

        public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let data = (try? JSONEncoder.pretty.encode(value)) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json", body: data)
        }

        public static func text(_ s: String, status: Int = 200) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8))
        }

        public static func error(_ status: Int, _ message: String) -> Response {
            json(["error": message], status: status)
        }
    }

    public typealias Handler = @Sendable (Request) async throws -> Response

    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "sendtox4.daemon.http", qos: .userInitiated)
    private var listener: NWListener?
    private var routes: [(method: String, path: String, handler: Handler)] = []
    private let routesLock = NSLock()

    public init(port: UInt16) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public func route(_ method: String, _ path: String, _ handler: @escaping Handler) {
        routesLock.lock(); defer { routesLock.unlock() }
        routes.append((method.uppercased(), path, handler))
    }

    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true                    // refuse non-loopback
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                fputs("[daemon] listening on 127.0.0.1:\(self.port.rawValue)\n", stderr)
            case .failed(let err):
                fputs("[daemon] listener failed: \(err)\n", stderr)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection lifecycle

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, accumulated: Data())
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error { self.fail(conn, error: error); return }

            var buffer = accumulated
            if let chunk = data { buffer.append(chunk) }

            // Look for end of headers.
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    self.fail(conn, error: NWError.posix(.ECONNRESET))
                } else {
                    if buffer.count > 4 * 1024 * 1024 {
                        self.fail(conn, error: NWError.posix(.E2BIG))
                        return
                    }
                    self.readRequest(conn, accumulated: buffer)
                }
                return
            }

            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            let bodyStart = headerEnd.upperBound

            guard let parsed = self.parseHeaders(headerData) else {
                self.write(conn, Response.error(400, "Bad request"))
                return
            }

            let contentLength = Int(parsed.headers["content-length"] ?? "0") ?? 0
            let alreadyHave = buffer.count - bodyStart
            if alreadyHave >= contentLength {
                let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                self.dispatch(conn, parsed: parsed, body: body)
            } else {
                self.readBody(conn, parsed: parsed, accumulated: buffer.subdata(in: bodyStart..<buffer.count), needed: contentLength)
            }
        }
    }

    private func readBody(_ conn: NWConnection, parsed: ParsedHeaders, accumulated: Data, needed: Int) {
        if accumulated.count >= needed {
            self.dispatch(conn, parsed: parsed, body: accumulated.subdata(in: 0..<needed))
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error { self.fail(conn, error: error); return }
            var next = accumulated
            if let chunk = data { next.append(chunk) }
            if next.count >= needed {
                self.dispatch(conn, parsed: parsed, body: next.subdata(in: 0..<needed))
            } else if isComplete {
                self.write(conn, Response.error(400, "Truncated body"))
            } else {
                self.readBody(conn, parsed: parsed, accumulated: next, needed: needed)
            }
        }
    }

    private struct ParsedHeaders: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String] // lowercased keys
    }

    private func parseHeaders(_ data: Data) -> ParsedHeaders? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        let (path, query) = parseTarget(target)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }
        return ParsedHeaders(method: method, path: path, query: query, headers: headers)
    }

    private func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let qs = String(target[target.index(after: q)...])
        var out: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let k = kv.first?.removingPercentEncoding ?? ""
            let v = (kv.count > 1 ? kv[1].removingPercentEncoding : "") ?? ""
            if !k.isEmpty { out[k] = v }
        }
        return (path, out)
    }

    private func dispatch(_ conn: NWConnection, parsed: ParsedHeaders, body: Data) {
        let req = Request(method: parsed.method, path: parsed.path, query: parsed.query, headers: parsed.headers, body: body)

        // Always allow CORS preflight from extension origins.
        if req.method == "OPTIONS" {
            self.writeRaw(conn, response: Response(status: 204, contentType: "text/plain", body: Data()), extraHeaders: corsHeaders())
            return
        }

        let handler: Handler? = {
            self.routesLock.lock(); defer { self.routesLock.unlock() }
            return self.routes.first(where: { $0.method == req.method && $0.path == req.path })?.handler
        }()
        guard let handler else {
            self.write(conn, Response.error(404, "Not found: \(req.method) \(req.path)"))
            return
        }
        Task {
            do {
                let resp = try await handler(req)
                self.write(conn, resp)
            } catch {
                self.write(conn, Response.error(500, "\(error)"))
            }
        }
    }

    // MARK: - Response writing

    private func corsHeaders() -> [(String, String)] {
        [
            ("Access-Control-Allow-Origin", "*"),
            ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
            ("Access-Control-Allow-Headers", "content-type"),
            ("Access-Control-Max-Age", "600")
        ]
    }

    private func write(_ conn: NWConnection, _ response: Response) {
        writeRaw(conn, response: response, extraHeaders: corsHeaders())
    }

    private func writeRaw(_ conn: NWConnection, response: Response, extraHeaders: [(String, String)]) {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func fail(_ conn: NWConnection, error: Error) {
        conn.cancel()
    }

    private func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }
}

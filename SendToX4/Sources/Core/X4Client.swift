import Foundation

/// HTTP client for the CrossPoint webserver running on the Xteink X4
/// during File Transfer mode. Plain HTTP, port 80, no auth, very small
/// surface (see docs/webserver-endpoints.md in the firmware repo).
public enum X4Client {

    public struct Status: Codable, Sendable {
        public var version: String?
        public var ip: String?
        public var mode: String?
        public var rssi: Int?
        public var freeHeap: Int?
        public var uptime: Int?

        public var looksLikeCrossPoint: Bool {
            // The pattern we trust: a JSON object with at least a `version`
            // string. The CrossPoint API includes it; random services on
            // port 80 will not.
            (version?.isEmpty == false)
        }
    }

    public struct FileEntry: Codable, Sendable {
        public var name: String
        public var size: Int?
        public var isDirectory: Bool?
        public var isEpub: Bool?
    }

    public enum Error: Swift.Error {
        case invalidURL
        case http(Int, String)
        case decode(String)
    }

    // MARK: - Endpoints

    public static func status(ip: String, timeout: TimeInterval = 1.0) async throws -> Status {
        guard let url = URL(string: "http://\(ip)/api/status") else { throw Error.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.http((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    public static func listFiles(ip: String, path: String = "/", timeout: TimeInterval = 5.0) async throws -> [FileEntry] {
        var components = URLComponents(string: "http://\(ip)/api/files")
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { throw Error.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Error.http((response as? HTTPURLResponse)?.statusCode ?? -1, "")
        }
        return try JSONDecoder().decode([FileEntry].self, from: data)
    }

    public static func upload(
        ip: String,
        filename: String,
        data: Data,
        path: String? = nil,
        timeout: TimeInterval = 60.0
    ) async throws {
        var components = URLComponents(string: "http://\(ip)/upload")
        if let path = path {
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
        }
        guard let url = components?.url else { throw Error.invalidURL }

        let boundary = "X4Upload\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/epub+zip\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.http(-1, "") }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: respData, encoding: .utf8) ?? ""
            throw Error.http(http.statusCode, text)
        }
    }

    /// Create a directory on the device. `name` is the folder name; `path`
    /// is the parent (defaults to root). The firmware's `/mkdir` is form-
    /// encoded (see SPEC.md API surface). Calling this when the directory
    /// already exists may return a 4xx — callers should tolerate that.
    public static func mkdir(
        ip: String,
        name: String,
        path: String? = nil,
        timeout: TimeInterval = 5.0
    ) async throws {
        guard let url = URL(string: "http://\(ip)/mkdir") else { throw Error.invalidURL }

        var fields: [(String, String)] = [("name", name)]
        if let path = path { fields.append(("path", path)) }
        let body = fields.map { "\($0.0)=\(percentEncodeFormValue($0.1))" }.joined(separator: "&")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)

        let (respData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.http(-1, "") }
        if !(200..<300).contains(http.statusCode) {
            let text = String(data: respData, encoding: .utf8) ?? ""
            throw Error.http(http.statusCode, text)
        }
    }
}

private func percentEncodeFormValue(_ s: String) -> String {
    // RFC 3986 unreserved set; everything else gets percent-encoded so the
    // server sees the value verbatim (incl. leading "/" in path values).
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

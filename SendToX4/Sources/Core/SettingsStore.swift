import Foundation
import Security

/// Persistent app settings. The Anthropic API key lives in the macOS Keychain;
/// everything else is a small JSON file.
public final class SettingsStore: @unchecked Sendable {
    public struct Snapshot: Codable, Sendable {
        public var lastKnownX4IP: String?
        public var x4HostnameHints: [String]
        public var autoFlush: Bool
        public var probeIntervalSeconds: Double
        public var subnetScanEnabled: Bool
        public var llmEnabled: Bool

        public init(
            lastKnownX4IP: String? = nil,
            x4HostnameHints: [String] = [],
            autoFlush: Bool = true,
            probeIntervalSeconds: Double = 5,
            subnetScanEnabled: Bool = true,
            llmEnabled: Bool = true
        ) {
            self.lastKnownX4IP = lastKnownX4IP
            self.x4HostnameHints = x4HostnameHints
            self.autoFlush = autoFlush
            self.probeIntervalSeconds = probeIntervalSeconds
            self.subnetScanEnabled = subnetScanEnabled
            self.llmEnabled = llmEnabled
        }
    }

    public static let shared = SettingsStore()

    private let lock = NSLock()
    private var cached: Snapshot

    public init() {
        self.cached = (try? Self.load()) ?? Snapshot()
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    public func update(_ mutate: (inout Snapshot) -> Void) throws {
        lock.lock()
        var copy = cached
        mutate(&copy)
        cached = copy
        let data = try JSONEncoder.pretty.encode(copy)
        lock.unlock()
        try data.write(to: AppPaths.settingsURL, options: [.atomic])
    }

    private static func load() throws -> Snapshot {
        let url = AppPaths.settingsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: - Keychain-backed API keys

    private static let anthropicAccount = "anthropic.api.key"
    private static let annasArchiveAccount = "annas-archive.api.key"

    public func anthropicAPIKey() -> String? {
        readKeychain(account: Self.anthropicAccount)
    }

    public func setAnthropicAPIKey(_ key: String?) throws {
        try writeKeychain(account: Self.anthropicAccount, value: key)
    }

    public func annasArchiveAPIKey() -> String? {
        readKeychain(account: Self.annasArchiveAccount)
    }

    public func setAnnasArchiveAPIKey(_ key: String?) throws {
        try writeKeychain(account: Self.annasArchiveAccount, value: key)
    }

    private func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppPaths.bundleId,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    private func writeKeychain(account: String, value: String?) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppPaths.bundleId,
            kSecAttrAccount as String: account
        ]
        // Always remove first; SecItemUpdate is fussy on some macOS versions.
        SecItemDelete(baseQuery as CFDictionary)
        guard let value = value, !value.isEmpty else { return }
        var attrs = baseQuery
        attrs[kSecValueData as String] = value.data(using: .utf8)!
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "SendToX4.Keychain", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Failed to save key for \(account) (OSStatus \(status))"
            ])
        }
    }
}

extension JSONEncoder {
    public static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    public static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

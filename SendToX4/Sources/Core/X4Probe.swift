import Foundation

/// Discovery loop for the X4. Strategy:
///
///   1. Try the last-known IP (1 s timeout). Most of the time this hits.
///   2. If it fails AND subnet scan is enabled, parallel-probe the local /24
///      for `/api/status` with a CrossPoint signature.
///   3. Cache the winning IP back into settings.
public actor X4Probe {

    public struct Result: Sendable {
        public var ip: String
        public var status: X4Client.Status
    }

    private let settings: SettingsStore
    private var probing = false

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    public func locate() async -> Result? {
        if probing { return nil }
        probing = true
        defer { probing = false }

        let snapshot = settings.snapshot

        // 1. Last-known IP.
        if let ip = snapshot.lastKnownX4IP, !ip.isEmpty {
            if let status = try? await X4Client.status(ip: ip, timeout: 1.0),
               status.looksLikeCrossPoint {
                return Result(ip: ip, status: status)
            }
        }

        // 2. Subnet scan.
        if snapshot.subnetScanEnabled, let subnet = LocalNetwork.primarySubnet() {
            if let result = await scanSubnet(subnet) {
                try? settings.update { s in
                    s.lastKnownX4IP = result.ip
                }
                return result
            }
        }

        return nil
    }

    private func scanSubnet(_ subnet: LocalNetwork.Subnet) async -> Result? {
        let candidates = subnet.candidateAddresses
        return await withTaskGroup(of: Result?.self) { group in
            for ip in candidates {
                group.addTask {
                    do {
                        let status = try await X4Client.status(ip: ip, timeout: 1.5)
                        if status.looksLikeCrossPoint {
                            return Result(ip: ip, status: status)
                        }
                    } catch {
                        // Most addresses won't respond — that's expected.
                    }
                    return nil
                }
            }
            for await result in group {
                if let result = result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }
}

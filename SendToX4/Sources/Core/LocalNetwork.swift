import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Best-effort discovery of the host's primary IPv4 address and /24 subnet.
/// Used as the seed for the X4 probe's subnet scan.
public enum LocalNetwork {

    public struct Subnet: Sendable {
        public var localIP: String
        public var prefix: String          // e.g. "192.168.1." (always 24-bit)
        public var hostOctet: Int          // 1...254 of `localIP`

        /// All addresses in the /24 except `localIP` and broadcast/network ends.
        public var candidateAddresses: [String] {
            (1...254).compactMap { i in
                if i == hostOctet { return nil }
                return prefix + "\(i)"
            }
        }
    }

    public static func primarySubnet() -> Subnet? {
        guard let ip = primaryIPv4Address() else { return nil }
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4, let host = Int(parts[3]) else { return nil }
        let prefix = parts[0] + "." + parts[1] + "." + parts[2] + "."
        return Subnet(localIP: ip, prefix: prefix, hostOctet: host)
    }

    public static func primaryIPv4Address() -> String? {
        #if canImport(Darwin)
        var ifaddrs_ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs_ptr) == 0, let first = ifaddrs_ptr else { return nil }
        defer { freeifaddrs(ifaddrs_ptr) }

        var best: String? = nil
        var ptr = first
        while true {
            let interface = ptr.pointee
            let name = String(cString: interface.ifa_name)
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            let isAFInet = interface.ifa_addr != nil &&
                interface.ifa_addr.pointee.sa_family == UInt8(AF_INET)
            if isUp && !isLoopback && isAFInet {
                var addr = interface.ifa_addr.pointee
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    &addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostBuffer, socklen_t(hostBuffer.count),
                    nil, 0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    let address = String(cString: hostBuffer)
                    if !address.hasPrefix("169.254.") {
                        // Prefer en0 / Wi-Fi style names.
                        if best == nil || name.hasPrefix("en") {
                            best = address
                        }
                    }
                }
            }
            if let nxt = interface.ifa_next {
                ptr = nxt
            } else {
                break
            }
        }
        return best
        #else
        return nil
        #endif
    }
}

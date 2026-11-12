import Darwin
import Foundation

public struct PreparedTunnelConfig {
    public let config: Data
    public let socksPort: Int
    public let credentials: ProxyCredentials
    public let serverAddress: String

    public init(config: Data, socksPort: Int, credentials: ProxyCredentials,
                serverAddress: String)
    {
        self.config = config
        self.socksPort = socksPort
        self.credentials = credentials
        self.serverAddress = serverAddress
    }
}

public enum TunnelConfigError: Error, Equatable {
    case malformedConfig
    case noSocksInbound
    case noProxyOutbound
    case noFreePort
    case unresolvableServer
    case ipv4ServerAddressRequired
}

/// Fills in the placeholders the Dart layer leaves behind.
///
/// `XrayConfig.build` emits `port: 0` and empty `accounts` on purpose, so the
/// Dart output stays deterministic and golden-testable. The provider picks a
/// free loopback port and mints per-session credentials here, inside the
/// extension, where they never cross a process boundary.
public enum TunnelXrayConfigPreparer {
    public static func prepare(_ raw: Data) throws -> PreparedTunnelConfig {
        guard var root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw TunnelConfigError.malformedConfig
        }

        let port = try freeLoopbackPort()
        let credentials = try ProxyCredentials.random()

        guard var inbounds = root["inbounds"] as? [[String: Any]],
              let index = inbounds.firstIndex(where: { $0["protocol"] as? String == "socks" })
        else {
            throw TunnelConfigError.noSocksInbound
        }

        inbounds[index]["port"] = port
        var settings = inbounds[index]["settings"] as? [String: Any] ?? [:]
        settings["auth"] = "password"
        settings["accounts"] = [["user": credentials.username, "pass": credentials.password]]
        inbounds[index]["settings"] = settings
        root["inbounds"] = inbounds

        guard let outbounds = root["outbounds"] as? [[String: Any]],
              let proxy = outbounds.first(where: { $0["tag"] as? String == "proxy" }),
              let proxySettings = proxy["settings"] as? [String: Any],
              let vnext = (proxySettings["vnext"] as? [[String: Any]])?.first,
              let serverAddress = vnext["address"] as? String
        else {
            throw TunnelConfigError.noProxyOutbound
        }

        return PreparedTunnelConfig(
            config: try JSONSerialization.data(withJSONObject: root),
            socksPort: port,
            credentials: credentials,
            serverAddress: serverAddress
        )
    }

    /// Rewrites the proxy outbound's `vnext.address` to an IPv4 literal.
    ///
    /// The provider excludes the addresses it resolved from the tunnel routes.
    /// Left dialling the hostname, Xray resolves again on every reconnect, and
    /// a round-robin or short-TTL record can hand it an address outside that
    /// set — which the tunnel then captures and routes back into Xray, hanging
    /// the session in `connected`. TLS `serverName` and the WebSocket `host`
    /// header are set separately, so both keep carrying the hostname.
    ///
    /// IPv4 is required by VlessPacketTunnelProvider.applyNetworkSettings:
    /// it installs no IPv6 excludedRoutes, and VlessPacketBridge drops IPv6
    /// before hev sees it. Reverting pinning to a hostname or IPv6 literal
    /// would capture and silently drop the VLESS transport itself. Keep these
    /// routing and address-family invariants together when adding IPv6 egress.
    public static func pinningServerAddress(
        _ prepared: PreparedTunnelConfig,
        to literal: String
    ) throws -> PreparedTunnelConfig {
        var address = in_addr()
        guard inet_pton(AF_INET, literal, &address) == 1 else {
            throw TunnelConfigError.ipv4ServerAddressRequired
        }
        guard var root = try? JSONSerialization.jsonObject(with: prepared.config) as? [String: Any],
              var outbounds = root["outbounds"] as? [[String: Any]],
              let index = outbounds.firstIndex(where: { $0["tag"] as? String == "proxy" }),
              var settings = outbounds[index]["settings"] as? [String: Any],
              var vnext = settings["vnext"] as? [[String: Any]],
              !vnext.isEmpty
        else {
            throw TunnelConfigError.noProxyOutbound
        }

        vnext[0]["address"] = literal
        settings["vnext"] = vnext
        outbounds[index]["settings"] = settings
        root["outbounds"] = outbounds

        return PreparedTunnelConfig(
            config: try JSONSerialization.data(withJSONObject: root),
            socksPort: prepared.socksPort,
            credentials: prepared.credentials,
            serverAddress: prepared.serverAddress
        )
    }

    /// Binds to port 0 and reads back what the kernel assigned, then closes.
    ///
    /// Racy in principle — another process could claim it in the gap — but the
    /// alternative, a fixed port, collides with whatever else is listening and
    /// fails every time instead of almost never.
    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TunnelConfigError.noFreePort }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw TunnelConfigError.noFreePort }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard read == 0 else { throw TunnelConfigError.noFreePort }

        let port = Int(UInt16(bigEndian: assigned.sin_port))
        guard port > 0 else { throw TunnelConfigError.noFreePort }
        return port
    }
}

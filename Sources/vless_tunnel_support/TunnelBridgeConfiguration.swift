import Foundation

/// Builds the configuration for the tun2socks bridge that moves packets between
/// the system tunnel interface and Xray's loopback SOCKS inbound.
public enum TunnelBridgeConfiguration {

    /// Non-obvious settings, and why:
    ///
    /// - `pipeline: false` — with pipelining the bridge sends CONNECT before
    ///   username/password authentication has completed, and the inbound
    ///   rejects it.
    /// - `udp: 'udp'` — carries UDP over a SOCKS UDP ASSOCIATE rather than
    ///   tunnelling it inside the TCP stream, which DNS needs.
    /// - `task-stack-size` — each connection gets its own coroutine stack, so
    ///   this multiplies by session count. Kept modest because an iOS Network
    ///   Extension is terminated past roughly 50 MB.
    public static func yaml(
        socksPort: Int,
        credentials: ProxyCredentials,
        mtu: Int,
        logPath: String
    ) -> String {
        """
        tunnel:
          mtu: \(mtu)
        socks5:
          address: 127.0.0.1
          port: \(socksPort)
          udp: 'udp'
          pipeline: false
          username: \(quoted(credentials.username))
          password: \(quoted(credentials.password))
        misc:
          task-stack-size: 86016
          tcp-buffer-size: 65536
          max-session-count: 512
          connect-timeout: 5000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: \(quoted(logPath))
          log-level: error
          limit-nofile: 65535
        """
    }

    /// Single-quoted YAML scalar; a literal quote is doubled.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

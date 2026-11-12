import XCTest

@testable import vless_tunnel_support

/// Covers the logic the provider depends on but cannot exercise without a live
/// NetworkExtension context.
final class TunnelXrayConfigPreparerTests: XCTestCase {

    /// The shape `XrayConfig.build` emits: port 0 and no accounts, for the
    /// provider to fill at startup.
    private let dartConfig = """
    {
      "inbounds": [{
        "tag": "socks-in",
        "protocol": "socks",
        "listen": "127.0.0.1",
        "port": 0,
        "settings": {"auth": "password", "accounts": [], "udp": true}
      }],
      "outbounds": [
        {
          "tag": "proxy",
          "protocol": "vless",
          "settings": {"vnext": [{
            "address": "supervpn-dc-testnet-01.mysterium.network",
            "port": 443,
            "users": [{"id": "b4cadb0d-886b-47ff-9edb-1f2d01612c28"}]
          }]}
        },
        {"tag": "block", "protocol": "blackhole"}
      ]
    }
    """

    private func prepared() throws -> PreparedTunnelConfig {
        try TunnelXrayConfigPreparer.prepare(Data(dartConfig.utf8))
    }

    func testFillsInAFreeLoopbackPort() throws {
        let result = try prepared()
        XCTAssertGreaterThan(result.socksPort, 0)
        XCTAssertLessThanOrEqual(result.socksPort, 65535)

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.config) as? [String: Any]
        )
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["port"] as? Int, result.socksPort)
    }

    func testInjectsTheMintedCredentials() throws {
        let result = try prepared()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.config) as? [String: Any]
        )
        let settings = try XCTUnwrap(
            (root["inbounds"] as? [[String: Any]])?.first?["settings"] as? [String: Any]
        )
        let account = try XCTUnwrap((settings["accounts"] as? [[String: Any]])?.first)

        XCTAssertEqual(account["user"] as? String, result.credentials.username)
        XCTAssertEqual(account["pass"] as? String, result.credentials.password)
        XCTAssertEqual(settings["auth"] as? String, "password")
    }

    func testReadsTheServerAddressFromTheProxyOutbound() throws {
        XCTAssertEqual(try prepared().serverAddress, "supervpn-dc-testnet-01.mysterium.network")
    }

    func testEachPreparationGetsFreshCredentials() throws {
        XCTAssertNotEqual(try prepared().credentials, try prepared().credentials)
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try TunnelXrayConfigPreparer.prepare(Data("{not json".utf8)))
    }

    func testRejectsAConfigWithNoSocksInbound() {
        let noInbound = #"{"inbounds": [], "outbounds": []}"#
        XCTAssertThrowsError(try TunnelXrayConfigPreparer.prepare(Data(noInbound.utf8))) { error in
            XCTAssertEqual(error as? TunnelConfigError, .noSocksInbound)
        }
    }

    func testPinningReplacesTheOutboundAddressWithTheLiteral() throws {
        let pinned = try TunnelXrayConfigPreparer.pinningServerAddress(prepared(), to: "203.0.113.7")
        let vnext = try firstVnext(in: pinned)
        XCTAssertEqual(vnext["address"] as? String, "203.0.113.7")
        XCTAssertEqual(vnext["port"] as? Int, 443)
    }

    func testPinningRejectsAddressesThatCannotBeExcludedFromTheTunnel() throws {
        let base = try prepared()
        // Hostnames re-resolve. The IPv4-in-IPv6 forms would be dialled as IPv4
        // while the provider excluded them as IPv6, capturing the transport.
        for address in ["vpn.example.com", "::ffff:203.0.113.7", "::203.0.113.7",
                        "203.0.113.999", "203.0.113.7:443", "[2001:db8::1]:443", ""] {
            XCTAssertThrowsError(
                try TunnelXrayConfigPreparer.pinningServerAddress(base, to: address),
                "\(address) must not be pinnable"
            ) {
                XCTAssertEqual($0 as? TunnelConfigError, .ipLiteralServerAddressRequired)
            }
        }
    }

    /// A NAT64 underlay has no IPv4 at all, so the transport itself is IPv6.
    /// `applyNetworkSettings` excludes it as an IPv6 route; without that pair
    /// the tunnel captures its own transport and the bridge discards it.
    func testPinningAcceptsAnIPv6LiteralForNAT64Underlays() throws {
        let pinned = try TunnelXrayConfigPreparer.pinningServerAddress(
            prepared(), to: "64:ff9b::cb00:7107"
        )
        let vnext = try firstVnext(in: pinned)
        XCTAssertEqual(vnext["address"] as? String, "64:ff9b::cb00:7107")
        XCTAssertEqual(vnext["port"] as? Int, 443)
    }

    /// The provider splits resolved addresses into per-family excluded routes
    /// using exactly this predicate, so disagreement would strand one family.
    func testIPv4LiteralsAreDistinguishedFromIPv6ForRouteExclusion() {
        for address in ["203.0.113.7", "0.0.0.0", "255.255.255.255"] {
            XCTAssertTrue(IPLiteral.isIPv4(address), address)
        }
        for address in ["64:ff9b::cb00:7107", "2001:db8::1", "::1", "vpn.example.com", ""] {
            XCTAssertFalse(IPLiteral.isIPv4(address), address)
        }
    }

    /// The whole point of pinning: the literal reaches the dialler while TLS and
    /// the WebSocket Host header keep the hostname, or the handshake fails.
    func testPinningLeavesSNIAndHostAlone() throws {
        let withTLS = """
        {
          "inbounds": [{"tag": "socks-in", "protocol": "socks", "listen": "127.0.0.1",
                        "port": 0, "settings": {"auth": "password", "accounts": []}}],
          "outbounds": [{
            "tag": "proxy", "protocol": "vless",
            "settings": {"vnext": [{"address": "vpn.example.com", "port": 443, "users": []}]},
            "streamSettings": {
              "network": "ws", "security": "tls",
              "tlsSettings": {"serverName": "vpn.example.com", "allowInsecure": false},
              "wsSettings": {"path": "/vless", "host": "vpn.example.com"}
            }
          }]
        }
        """
        let base = try TunnelXrayConfigPreparer.prepare(Data(withTLS.utf8))
        let pinned = try TunnelXrayConfigPreparer.pinningServerAddress(base, to: "198.51.100.9")

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: pinned.config) as? [String: Any])
        let proxy = try XCTUnwrap((root["outbounds"] as? [[String: Any]])?.first)
        let stream = try XCTUnwrap(proxy["streamSettings"] as? [String: Any])
        let tls = try XCTUnwrap(stream["tlsSettings"] as? [String: Any])
        let ws = try XCTUnwrap(stream["wsSettings"] as? [String: Any])

        XCTAssertEqual(try firstVnext(in: pinned)["address"] as? String, "198.51.100.9")
        XCTAssertEqual(tls["serverName"] as? String, "vpn.example.com")
        XCTAssertEqual(ws["host"] as? String, "vpn.example.com")
    }

    func testPinningCarriesThePortAndCredentialsThrough() throws {
        let base = try prepared()
        let pinned = try TunnelXrayConfigPreparer.pinningServerAddress(base, to: "203.0.113.7")
        XCTAssertEqual(pinned.socksPort, base.socksPort)
        XCTAssertEqual(pinned.credentials.username, base.credentials.username)
        XCTAssertEqual(pinned.credentials.password, base.credentials.password)
        // Still the hostname: the provider logs it and resolves against it.
        XCTAssertEqual(pinned.serverAddress, base.serverAddress)
    }

    func testPinningRejectsAConfigWithNoProxyOutbound() throws {
        let base = try prepared()
        let stripped = PreparedTunnelConfig(
            config: Data(#"{"outbounds": [{"tag": "direct"}]}"#.utf8),
            socksPort: base.socksPort,
            credentials: base.credentials,
            serverAddress: base.serverAddress
        )
        XCTAssertThrowsError(
            try TunnelXrayConfigPreparer.pinningServerAddress(stripped, to: "203.0.113.7")
        ) { XCTAssertEqual($0 as? TunnelConfigError, .noProxyOutbound) }
    }

    private func firstVnext(in config: PreparedTunnelConfig) throws -> [String: Any] {
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: config.config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "proxy" })
        let settings = try XCTUnwrap(proxy["settings"] as? [String: Any])
        return try XCTUnwrap((settings["vnext"] as? [[String: Any]])?.first)
    }

    func testRejectsAConfigWithNoProxyOutbound() {
        let noProxy = """
        {"inbounds": [{"protocol": "socks", "settings": {}}], "outbounds": []}
        """
        XCTAssertThrowsError(try TunnelXrayConfigPreparer.prepare(Data(noProxy.utf8))) { error in
            XCTAssertEqual(error as? TunnelConfigError, .noProxyOutbound)
        }
    }
}

final class ProxyCredentialsTests: XCTestCase {

    func testGeneratesDistinctHexCredentials() throws {
        let first = try ProxyCredentials.random()
        let second = try ProxyCredentials.random()

        XCTAssertEqual(first.username.count, 32)   // 128-bit
        XCTAssertEqual(first.password.count, 64)   // 256-bit
        XCTAssertNotEqual(first, second)
    }

    func testRejectsControlCharacters() {
        XCTAssertThrowsError(try ProxyCredentials(username: "a\u{0}b", password: "ok"))
    }

    func testRejectsEmptyValues() {
        XCTAssertThrowsError(try ProxyCredentials(username: "", password: "ok"))
    }

    /// Credentials must never reach a log.
    func testDescriptionDoesNotLeakTheSecret() throws {
        let credentials = try ProxyCredentials.random()
        XCTAssertFalse("\(credentials)".contains(credentials.password))
        XCTAssertFalse(credentials.debugDescription.contains(credentials.password))
    }
}

final class TunnelBridgeConfigurationTests: XCTestCase {

    private func config() throws -> String {
        TunnelBridgeConfiguration.yaml(
            socksPort: 10808,
            credentials: try ProxyCredentials(username: "user", password: "pass"),
            mtu: 1500,
            logPath: "/tmp/hev.log"
        )
    }

    func testCarriesPortCredentialsAndMTU() throws {
        let yaml = try config()
        XCTAssertTrue(yaml.contains("port: 10808"))
        XCTAssertTrue(yaml.contains("mtu: 1500"))
        XCTAssertTrue(yaml.contains("username: 'user'"))
        XCTAssertTrue(yaml.contains("password: 'pass'"))
    }

    /// Pipelining would send CONNECT before authentication completes.
    func testDisablesPipelining() throws {
        XCTAssertTrue(try config().contains("pipeline: false"))
    }

    func testQuotesValuesContainingQuotes() throws {
        let yaml = TunnelBridgeConfiguration.yaml(
            socksPort: 1,
            credentials: try ProxyCredentials(username: "a'b", password: "p"),
            mtu: 1500,
            logPath: "/tmp/hev.log"
        )
        XCTAssertTrue(yaml.contains("username: 'a''b'"))
    }
}

final class TunnelWorkerLifecycleTests: XCTestCase {

    /// A worker that returns immediately must not be reported as a live tunnel.
    func testImmediateExitIsReportedAsExited() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()
        lifecycle.markExited(code: 3)

        XCTAssertEqual(lifecycle.waitForStableStartup(gracePeriod: 0.05), .exited(code: 3))
        XCTAssertFalse(lifecycle.isRunning)
    }

    func testStayingUpThroughTheGracePeriodIsRunning() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()

        XCTAssertEqual(lifecycle.waitForStableStartup(gracePeriod: 0.05), .running)
        XCTAssertTrue(lifecycle.isRunning)
    }

    func testAThreadThatNeverStartsIsDistinguished() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()

        XCTAssertEqual(lifecycle.waitForStableStartup(gracePeriod: 0.05), .neverStarted)
    }

    /// An exit nobody asked for is a crash and should be reported as such.
    func testUnrequestedExitIsFlaggedUnexpected() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()

        XCTAssertTrue(lifecycle.markExited(code: 1))
    }

    func testExitAfterAStopRequestIsExpected() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()
        _ = lifecycle.requestStop()

        XCTAssertFalse(lifecycle.markExited(code: 0))
    }

    /// Only the first caller owns the shutdown.
    func testOnlyTheFirstStopRequestClaimsIt() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()

        XCTAssertTrue(lifecycle.requestStop())
        XCTAssertFalse(lifecycle.requestStop())
        XCTAssertTrue(lifecycle.isStopRequested)
    }

    /// teardown() uses timeout 0 as a non-blocking check before forcing a quit.
    func testWaitForExitWithZeroTimeoutDoesNotBlock() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()

        let started = Date()
        XCTAssertFalse(lifecycle.waitForExit(timeout: 0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
    }

    func testWaitForExitWakesWhenTheWorkerReturns() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            lifecycle.markExited(code: 0)
        }
        XCTAssertTrue(lifecycle.waitForExit(timeout: 2))
    }

    func testBeginStartClearsPreviousState() {
        let lifecycle = TunnelWorkerLifecycle()
        lifecycle.beginStart()
        lifecycle.markThreadEntered()
        _ = lifecycle.requestStop()
        lifecycle.markExited(code: 9)

        lifecycle.beginStart()
        XCTAssertFalse(lifecycle.isStopRequested)
        XCTAssertFalse(lifecycle.isRunning)
        XCTAssertFalse(lifecycle.waitForExit(timeout: 0))
    }
}

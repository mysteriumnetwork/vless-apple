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

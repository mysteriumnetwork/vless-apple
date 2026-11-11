//
//  Shared packet tunnel provider for iOS and macOS.
//
//  Each platform's extension target subclasses this, so the data plane lives in
//  one place rather than being copied per platform.
//

import Foundation
import NetworkExtension
import Tun2SocksKit
import XRay
import os

private let tunnelMTU = 1500
private let tunnelAddress = "198.18.0.1"
// ULA, so capturing IPv6 cannot collide with a real prefix on the network.
private let tunnelAddressIPv6 = "fd00:198:18::1"
private let hevStartupGrace: TimeInterval = 0.25
private let hevShutdownTimeout: TimeInterval = 2

private let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "vless_dart.tunnel",
    category: "tunnel"
)

open class VlessPacketTunnelProvider: NEPacketTunnelProvider {
    private let hev = TunnelWorkerLifecycle()
    private let runtimeQueue = DispatchQueue(label: "com.mysteriumvpn.vless.runtime")
    private var hevLogURL: URL?
    private var started = false
    private var footprintTimer: DispatchSourceTimer?

    override public init() { super.init() }

    override open func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("[TUNNEL] startTunnel", log: log, type: .info)

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            os_log("[TUNNEL] protocolConfiguration is not NETunnelProviderProtocol",
                   log: log, type: .error)
            completionHandler(TunnelConfigError.malformedConfig)
            return
        }
        guard let raw = proto.providerConfiguration?["config"] as? Data else {
            os_log("[TUNNEL] providerConfiguration missing \"config\"; keys=%@",
                   log: log, type: .error,
                   String(describing: proto.providerConfiguration?.keys.sorted()))
            completionHandler(TunnelConfigError.malformedConfig)
            return
        }
        os_log("[TUNNEL] config %d bytes", log: log, type: .info, raw.count)

        let prepared: PreparedTunnelConfig
        do {
            prepared = try TunnelXrayConfigPreparer.prepare(raw)
        } catch {
            os_log("[TUNNEL] config prepare failed: %@", log: log, type: .error, "\(error)")
            completionHandler(error)
            return
        }

        // Not yet forwarding — the app maps `reasserting` to `connecting`, so
        // the UI cannot show connected over a tunnel that drops packets.
        reasserting = true

        os_log("[TUNNEL] prepared; server=%@ socksPort=%d", log: log, type: .info,
               prepared.serverAddress, prepared.socksPort)

        applyNetworkSettings(serverAddress: prepared.serverAddress) { [weak self] error in
            guard let self else {
                os_log("[TUNNEL] provider deallocated during setup", log: log, type: .error)
                completionHandler(TunnelConfigError.malformedConfig)
                return
            }
            if let error {
                os_log("[TUNNEL] setTunnelNetworkSettings failed: %@", log: log, type: .error,
                       error.localizedDescription)
                completionHandler(error)
                return
            }
            os_log("[TUNNEL] network settings applied", log: log, type: .info)
            self.runtimeQueue.async {
                do {
                    try self.startRuntime(prepared)
                    self.reasserting = false
                    self.started = true
                    os_log("[TUNNEL] forwarding ready", log: log, type: .info)
                    self.startFootprintSampling()
                    completionHandler(nil)
                } catch {
                    os_log("[TUNNEL] start failed: %@", log: log, type: .error, "\(error)")
                    self.teardown()
                    completionHandler(error)
                }
            }
        }
    }

    override open func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("[TUNNEL] stopTunnel: %d", log: log, type: .info, reason.rawValue)
        teardown()
        completionHandler()
    }

    override open func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard String(data: messageData, encoding: .utf8) == vlessStatsProviderMessage else {
            completionHandler?(nil)
            return
        }
        let stats = Socks5Tunnel.stats
        var payload: [String: Any] = [
            "totalDownload": stats.down.bytes,
            "totalUpload": stats.up.bytes,
            "latestHandshake": 0,
        ]
        // The extension's own footprint — the app cannot measure this itself,
        // and it is the number that decides whether jetsam kills the tunnel.
        if let footprint = Self.footprintBytes() {
            payload["footprintBytes"] = footprint
        }
        completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: - Runtime

    private func startRuntime(_ prepared: PreparedTunnelConfig) throws {
        XRaySetMemoryLimit()

        var xrayError: NSError?
        XRayStart(prepared.config, &xrayError)
        if let xrayError { throw xrayError }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hev-socks5-tunnel.log")
        hevLogURL = logURL

        let hevConfig = TunnelBridgeConfiguration.yaml(
            socksPort: prepared.socksPort,
            credentials: prepared.credentials,
            mtu: tunnelMTU,
            logPath: logURL.path
        )

        hev.beginStart()
        Thread {
            self.hev.markThreadEntered()
            guard !self.hev.isStopRequested else {
                _ = self.hev.markExited(code: 0)
                return
            }
            let code = Socks5Tunnel.run(withConfig: .string(content: hevConfig))
            _ = self.hev.markExited(code: code)
        }.start()

        switch hev.waitForStableStartup(gracePeriod: hevStartupGrace) {
        case .running:
            return
        default:
            throw TunnelConfigError.noFreePort
        }
    }

    private func teardown() {
        started = false
        footprintTimer?.cancel()
        footprintTimer = nil

        // Unconditional: during the startup window neither `started` nor
        // `isRunning` is true yet, and skipping the stop there leaks the worker
        // so the next connect spawns a second one.
        _ = hev.requestStop()

        // quit() is what makes the blocking Socks5Tunnel.run return; waiting
        // first would just burn the whole timeout every disconnect.
        if !hev.waitForExit(timeout: 0) {
            Socks5Tunnel.quit()
            _ = hev.waitForExit(timeout: hevShutdownTimeout)
        }

        XRayStop()
    }

    // MARK: - Memory

    /// iOS kills a Network Extension past roughly 50 MB, and it measures
    /// `phys_footprint` — not resident size. Sampling it is the only way to know
    /// how much headroom a running tunnel actually has.
    public static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private func startFootprintSampling() {
        footprintTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: runtimeQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { [weak self] in
            guard self != nil, let bytes = Self.footprintBytes() else { return }
            let stats = Socks5Tunnel.stats
            os_log("[TUNNEL] footprint=%.1f MB down=%d up=%d", log: log, type: .info,
                   Double(bytes) / 1_048_576, stats.down.bytes, stats.up.bytes)
        }
        timer.resume()
        footprintTimer = timer
    }

    // MARK: - Network settings

    /// The direct route for [serverAddress] is load-bearing: without it the
    /// tunnel routes its own VLESS transport back into itself and deadlocks.
    private func applyNetworkSettings(
        serverAddress: String,
        completion: @escaping (Error?) -> Void
    ) {
        // tunnelRemoteAddress must be an IP literal; a hostname is rejected with
        // NETunnelProviderErrorDomain Code=1.
        let addresses = resolveAll(serverAddress, family: AF_INET)
        let addresses6 = resolveAll(serverAddress, family: AF_INET6)
        guard let resolved = addresses.first else {
            os_log("[TUNNEL] cannot resolve %@", log: log, type: .error, serverAddress)
            completion(TunnelConfigError.unresolvableServer)
            return
        }
        os_log("[TUNNEL] applying settings; server=%@ -> %@", log: log, type: .info,
               serverAddress, resolved)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: resolved)
        settings.mtu = NSNumber(value: tunnelMTU)

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // Without these the tunnel routes its own VLESS transport into itself.
        // Every A record is excluded, not just the one used as the remote
        // address, because Xray dials by hostname and may pick any of them.
        ipv4.excludedRoutes = addresses.map {
            NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
        }
        settings.ipv4Settings = ipv4

        // Capture IPv6 as well. Leaving ipv6Settings nil does not disable the
        // device's physical IPv6 — it routes it outside the tunnel, which on a
        // dual-stack network leaks the user's real address for everything that
        // prefers IPv6. Captured traffic is dropped by the ::/0 routing rule in
        // the Xray config, so clients fall back to IPv4.
        let ipv6 = NEIPv6Settings(addresses: [tunnelAddressIPv6], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = addresses6.map {
            NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128)
        }
        settings.ipv6Settings = ipv6

        // Public resolvers reached through the tunnel. A virtual DNS server
        // would need Xray's DNS app, which the trimmed distro leaves out.
        let dns = NEDNSSettings(servers: ["1.1.1.1", "1.0.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    /// Every address the host resolves to in [family], so all of them can be
    /// excluded from the tunnel.
    private func resolveAll(_ host: String, family: Int32) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: family, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0 else { return [] }
        defer { freeaddrinfo(info) }

        var out: [String] = []
        var node = info
        while let current = node {
            if let addr = current.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let printed: Bool
                if family == AF_INET6 {
                    var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee
                    }
                    printed = inet_ntop(
                        AF_INET6, &sin6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)
                    ) != nil
                } else {
                    var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }
                    printed = inet_ntop(
                        AF_INET, &sin.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)
                    ) != nil
                }
                if printed {
                    let text = String(cString: buffer)
                    if !out.contains(text) {
                        out.append(text)
                    }
                }
            }
            node = current.pointee.ai_next
        }
        return out
    }

}

import Darwin
import Foundation
import VlessPacketBridge
import XCTest

final class TunnelPacketBridgeTests: XCTestCase {
    private func pair() throws -> [Int32] {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return fds
    }

    private func frame(_ version: UInt8, family: Int32? = nil, payload: [UInt8] = []) -> [UInt8] {
        let af = UInt32(family ?? (version == 6 ? AF_INET6 : AF_INET)).bigEndian
        return withUnsafeBytes(of: af) { Array($0) } +
            [version << 4 | 5] + [UInt8](repeating: 0, count: 19) + payload
    }

    private func send(_ bytes: [UInt8], to fd: Int32) throws {
        let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == bytes.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func receive(_ fd: Int32, timeout: Int32 = 1000) throws -> [UInt8]? {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, timeout) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65540)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return Array(bytes.prefix(count))
    }

    private func withBridge(_ body: (Int32, Int32, OpaquePointer) throws -> Void) throws {
        let fds = try pair()
        defer { fds.forEach { Darwin.close($0) } }
        let bridge = try XCTUnwrap(vless_packet_bridge_start(fds[0]))
        defer { XCTAssertEqual(vless_packet_bridge_stop(bridge), 0) }
        try body(fds[1], vless_packet_bridge_descriptor(bridge), bridge)
    }

    /// An I/O failure must not wedge teardown. hev_socks5_tunnel_quit() blocks
    /// forever when hev was never started, and stop() joins the forwarder — so
    /// quitting on that thread hangs the whole disconnect. No other test drives
    /// the forwarder into its error path, which is how that went unnoticed.
    func testForwarderErrorDoesNotHangTeardown() throws {
        let fds = try pair()
        let bridge = try XCTUnwrap(vless_packet_bridge_start(fds[0]))
        // The bridge holds a dup; closing both originals strands it on a dead
        // peer, so poll reports POLLHUP and the forwarder takes its error path.
        fds.forEach { Darwin.close($0) }
        // Let the forwarder observe POLLHUP first; stopping immediately would
        // take the clean-shutdown branch and never exercise the error path.
        Thread.sleep(forTimeInterval: 0.2)

        var result: Int32 = -1
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result = vless_packet_bridge_stop(bridge)
            stopped.signal()
        }
        XCTAssertEqual(stopped.wait(timeout: .now() + 5), .success,
                       "stop() blocked — the quit is back on the forwarder thread")
        XCTAssertNotEqual(result, 0, "the forwarder should have recorded the I/O error")
    }

    func testPreservesIPv4DatagramsInBothDirections() throws {
        try withBridge { tunnel, hev, _ in
            let first = frame(4, payload: [1, 2, 3])
            let second = frame(4, payload: [4, 5])
            try send(first, to: tunnel)
            try send(second, to: tunnel)
            XCTAssertEqual(try receive(hev), first)
            XCTAssertEqual(try receive(hev), second)
            try send(second, to: hev)
            try send(first, to: hev)
            XCTAssertEqual(try receive(tunnel), second)
            XCTAssertEqual(try receive(tunnel), first)
        }
    }

    func testDropsIPv6BeforeHevAndKeepsForwardingIPv4() throws {
        try withBridge { tunnel, hev, bridge in
            try send(frame(6), to: tunnel)
            XCTAssertNil(try receive(hev, timeout: 100))
            let ipv4 = frame(4)
            try send(ipv4, to: tunnel)
            XCTAssertEqual(try receive(hev), ipv4)
            XCTAssertEqual(vless_packet_bridge_dropped_ipv6(bridge), 1)
        }
    }

    func testDropsIPv6FromHevInsteadOfEmittingItIntoTheTunnel() throws {
        try withBridge { tunnel, hev, bridge in
            try send(frame(6), to: hev)
            let ipv4 = frame(4)
            try send(ipv4, to: hev)
            XCTAssertEqual(try receive(tunnel), ipv4)
            XCTAssertEqual(vless_packet_bridge_dropped_ipv6(bridge), 1)
        }
    }

    func testFailsClosedOnMalformedOrMismatchedFrames() throws {
        try withBridge { tunnel, hev, _ in
            for packet in [[UInt8](repeating: 0, count: 4),
                           frame(4, family: AF_INET6),
                           frame(6, family: AF_INET),
                           frame(4, family: AF_UNSPEC)] {
                try send(packet, to: tunnel)
            }
            let ipv4 = frame(4, payload: [9])
            try send(ipv4, to: tunnel)
            XCTAssertEqual(try receive(hev), ipv4)
            XCTAssertNil(try receive(hev, timeout: 100))
        }
    }

    func testZeroLengthDatagramsDoNotTearDownEitherDirection() throws {
        try withBridge { tunnel, hev, _ in
            let ipv4 = frame(4, payload: [1, 2, 3])
            try send([], to: tunnel)
            try send(ipv4, to: tunnel)
            XCTAssertEqual(try receive(hev), ipv4)
            try send([], to: hev)
            try send(ipv4, to: hev)
            XCTAssertEqual(try receive(tunnel), ipv4)
        }
    }

    func testStopWakesIdleForwarderAndKeepsTheBorrowedDescriptorOpen() throws {
        let fds = try pair()
        defer { fds.forEach { Darwin.close($0) } }
        let bridge = try XCTUnwrap(vless_packet_bridge_start(fds[0]))
        let start = Date()
        XCTAssertEqual(vless_packet_bridge_stop(bridge), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertGreaterThanOrEqual(fcntl(fds[0], F_GETFD), 0)
    }

    func testStopWakesBackpressuredForwarder() throws {
        let fds = try pair()
        defer { fds.forEach { Darwin.close($0) } }
        let bridge = try XCTUnwrap(vless_packet_bridge_start(fds[0]))
        // Don't drain hev: fill the datagram queues until the writer backs up.
        XCTAssertEqual(fcntl(fds[1], F_SETFL, O_NONBLOCK), 0)
        let packet = frame(4, payload: [UInt8](repeating: 1, count: 1400))
        var backpressured = false
        for _ in 0..<10000 {
            let count = packet.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) }
            if count < 0 {
                XCTAssertTrue(errno == EAGAIN || errno == ENOBUFS)
                backpressured = true
                break
            }
        }
        XCTAssertTrue(backpressured)
        let start = Date()
        XCTAssertEqual(vless_packet_bridge_stop(bridge), 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testRejectsAnInvalidDescriptor() {
        XCTAssertNil(vless_packet_bridge_start(-1))
        XCTAssertEqual(errno, EBADF)
    }

    func testIPv4ResumesWithoutLossAfterBackpressure() throws {
        try withBridge { tunnel, hev, _ in
            XCTAssertEqual(fcntl(tunnel, F_SETFL, O_NONBLOCK), 0)
            let completed = DispatchSemaphore(value: 0)
            let packets = (0..<128).map { index in
                frame(4, payload: [UInt8(index)] + [UInt8](repeating: 7, count: 1400))
            }
            DispatchQueue.global().async {
                defer { completed.signal() }
                let deadline = Date().addingTimeInterval(5)
                for packet in packets {
                    while true {
                        let count = packet.withUnsafeBytes {
                            Darwin.write(tunnel, $0.baseAddress, $0.count)
                        }
                        if count == packet.count { break }
                        guard count < 0, errno == EAGAIN || errno == ENOBUFS,
                              Date() < deadline else {
                            XCTFail("IPv4 writer did not recover from backpressure")
                            return
                        }
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                }
            }
            defer { XCTAssertEqual(completed.wait(timeout: .now() + 6), .success) }
            // Let the writer fill both queues before draining the hev side.
            Thread.sleep(forTimeInterval: 0.02)
            for packet in packets {
                let received = try XCTUnwrap(try receive(hev))
                XCTAssertEqual(received, packet)
            }
        }
    }

    /// Exercise the actual pinned hev binary, not a mock TCP stack. An IPv6
    /// SYN must produce no response; an IPv4 SYN must still receive a SYN-ACK.
    func testRealHevAcknowledgesIPv4ButNeverIPv6() throws {
        let fds = try pair()
        defer { fds.forEach { Darwin.close($0) } }
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 8), 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &size)
            }
        }
        let config = """
        tunnel:
          mtu: 1500
        socks5:
          address: 127.0.0.1
          port: \(UInt16(bigEndian: address.sin_port))
          pipeline: false
        misc:
          log-level: error
        """
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let result = config.withCString {
                vless_ipv4_socks5_run_on_descriptor($0, config.utf8.count, fds[0])
            }
            XCTAssertEqual(result, 0)
            exited.signal()
        }
        defer {
            // quit may race hev's initialization; keep waking until it exits.
            var stopped = false
            for _ in 0..<100 {
                vless_ipv4_socks5_quit()
                if exited.wait(timeout: .now() + 0.02) == .success {
                    stopped = true
                    break
                }
            }
            XCTAssertTrue(stopped, "hev must exit and release its forwarding thread")
        }
        try send(tcpSYN(ipv6: true), to: fds[1])
        XCTAssertNil(try receive(fds[1], timeout: 250), "IPv6 must not get a synthetic SYN-ACK")
        try send(tcpSYN(ipv6: false), to: fds[1])
        let reply = try XCTUnwrap(try receive(fds[1]))
        guard reply.count >= 24 else {
            XCTFail("Truncated IPv4 reply")
            return
        }
        XCTAssertEqual(reply[4] >> 4, 4)
        let tcp = 4 + Int(reply[4] & 0x0f) * 4
        guard reply.count > tcp + 13 else {
            XCTFail("Truncated TCP reply")
            return
        }
        XCTAssertEqual(reply[tcp + 13] & 0x12, 0x12, "IPv4 still receives SYN+ACK")
    }

    private func tcpSYN(ipv6: Bool) -> [UInt8] {
        var tcp: [UInt8] = [0x9c, 0x40, 0x01, 0xbb, 0, 0, 0x30, 0x39,
                           0, 0, 0, 0, 0x50, 0x02, 0xff, 0xff, 0, 0, 0, 0]
        var ip: [UInt8]
        var pseudo: [UInt8]
        if ipv6 {
            let src: [UInt8] = [0xfd, 0, 0x01, 0x98, 0, 0x18] + [UInt8](repeating: 0, count: 9) + [1]
            let dst: [UInt8] = [0x20, 1, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
            ip = [0x60, 0, 0, 0, 0, 20, 6, 64] + src + dst
            pseudo = src + dst + [0, 0, 0, 20, 0, 0, 0, 6]
        } else {
            let src: [UInt8] = [198, 18, 0, 1]
            let dst: [UInt8] = [203, 0, 113, 9]
            ip = [0x45, 0, 0, 40, 0, 1, 0x40, 0, 64, 6, 0, 0] + src + dst
            let sum = checksum(ip)
            ip[10] = UInt8(sum >> 8)
            ip[11] = UInt8(sum & 0xff)
            pseudo = src + dst + [0, 6, 0, 20]
        }
        let sum = checksum(pseudo + tcp)
        tcp[16] = UInt8(sum >> 8)
        tcp[17] = UInt8(sum & 0xff)
        let af = UInt32(ipv6 ? AF_INET6 : AF_INET).bigEndian
        return withUnsafeBytes(of: af) { Array($0) } + ip + tcp
    }

    private func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: bytes.count, by: 2) {
            sum += UInt32(bytes[i]) << 8 | (i + 1 < bytes.count ? UInt32(bytes[i + 1]) : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

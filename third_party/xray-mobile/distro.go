package XRay

// The supported feature set, and nothing else.
//
// Xray-core registers protocols and transports through init() side effects, so
// this import list IS the contract: VLESS over WebSocket + TLS, with a local
// SOCKS inbound. Adding a protocol or transport means editing this file, which
// makes it a visible, reviewable change.
//
// Deliberately absent: XHTTP, SplitHTTP, HTTPUpgrade, gRPC, QUIC, mKCP,
// REALITY, VMess, Trojan, Shadowsocks, WireGuard, DNS and routing. Keeping them
// out holds the binary and the runtime footprint down, which matters because an
// iOS Network Extension is jetsam-killed past roughly 50 MB.
//
// Never fall back to main/distro/all; that defeats the entire design.

import (
	// Mandatory.
	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"

	// Logging, traffic counters and the level policy the counters hang off.
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/stats"

	// Routing, so IPv6 can be null-routed inside the tunnel instead of leaking
	// around it. Free: infra/conf already pulls this into the closure.
	_ "github.com/xtls/xray-core/app/router"

	// Inbound: the loopback SOCKS the tun2socks bridge talks to.
	_ "github.com/xtls/xray-core/proxy/socks"

	// Outbounds: the VLESS proxy, plus direct and block.
	_ "github.com/xtls/xray-core/proxy/blackhole"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"

	// Transports. udp is required by the SOCKS inbound's udp:true.
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
	_ "github.com/xtls/xray-core/transport/internet/udp"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
)

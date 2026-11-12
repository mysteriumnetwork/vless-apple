#ifndef VLESS_PACKET_BRIDGE_H
#define VLESS_PACKET_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

// A packet-preserving adapter between a Darwin utun and hev. Only IPv4 enters
// hev, so an IPv6 SYN cannot receive a synthetic SYN-ACK from its TCP stack.
struct vless_packet_bridge;
struct vless_packet_bridge *vless_packet_bridge_start(int tunnel_fd);
int vless_packet_bridge_descriptor(const struct vless_packet_bridge *bridge);
uint64_t vless_packet_bridge_dropped_ipv6(const struct vless_packet_bridge *bridge);
// Non-zero once this bridge's forwarding thread has failed. Safe to inspect
// while the owner retains the bridge; it does not inspect another session.
int vless_packet_bridge_failed(const struct vless_packet_bridge *bridge);
// Stops the forwarding thread, closes owned descriptors and frees the bridge.
// Returns a forwarding errno, or zero for an intentional shutdown.
int vless_packet_bridge_stop(struct vless_packet_bridge *bridge);

// Finds this extension's utun and runs the existing hev binary through the
// adapter. Uses the pinned hev archive, with init/run/cleanup synchronized by
// the adapter. Tun2SocksKit still supplies stats; no third-party fork.
int vless_ipv4_socks5_run(const char *config, size_t config_length);
// Explicit fd entry point, also usable with packet-preserving socket pairs.
// The caller retains ownership of tunnel_fd.
int vless_ipv4_socks5_run_on_descriptor(const char *config, size_t config_length, int tunnel_fd);
// Non-zero once the forwarding thread has died. hev can be healthy while
// the bridge is not, which would report a started tunnel that carries
// nothing, so startup must check this before declaring success.
int vless_ipv4_socks5_forwarder_failed(void);
// Recheck cancellation after registration, closing the gap between the provider's
// earlier stop check and entry into C. Called once, without adapter locks held;
// the context must remain alive until run returns. A nonzero result cancels init.
typedef int (*vless_socks5_stop_check)(void *context);
int vless_ipv4_socks5_run_with_stop_check(const char *config, size_t config_length,
                                        vless_socks5_stop_check stop_check, void *context);
int vless_ipv4_socks5_run_on_descriptor_with_stop_check(
    const char *config, size_t config_length, int tunnel_fd,
    vless_socks5_stop_check stop_check, void *context);
void vless_ipv4_socks5_quit(void);

#endif

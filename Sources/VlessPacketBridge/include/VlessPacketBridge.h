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
// Stops the forwarding thread, closes owned descriptors and frees the bridge.
// Returns a forwarding errno, or zero for an intentional shutdown.
int vless_packet_bridge_stop(struct vless_packet_bridge *bridge);

// Finds this extension's utun and runs the existing hev binary through the
// adapter. Tun2SocksKit still supplies stats and quit; no third-party fork.
int vless_ipv4_socks5_run(const char *config, size_t config_length);
// Explicit fd entry point, also usable with packet-preserving socket pairs.
// The caller retains ownership of tunnel_fd.
int vless_ipv4_socks5_run_on_descriptor(const char *config, size_t config_length, int tunnel_fd);
void vless_ipv4_socks5_quit(void);

#endif

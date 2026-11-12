#include "VlessPacketBridge.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

// Darwin kernel-control ABI, also used by Tun2SocksKit. These structures are
// absent from the iOS SDK headers, so do not include macOS-only kern_control.h.
#define VLESS_CTLIOCGINFO 0xc0644e03UL
struct vless_ctl_info {
    uint32_t id;
    char name[96];
};
struct vless_sockaddr_ctl {
    uint8_t length;
    uint8_t family;
    uint16_t sysaddr;
    uint32_t id;
    uint32_t unit;
    uint32_t reserved[5];
};
_Static_assert(sizeof(struct vless_ctl_info) == 100, "Darwin ctl_info ABI");
_Static_assert(sizeof(struct vless_sockaddr_ctl) == 32, "Darwin sockaddr_ctl ABI");

// Exported by the pinned HevSocks5Tunnel archive linked by Tun2SocksKit.
extern int hev_socks5_tunnel_main_from_str(const unsigned char *, unsigned int, int);
extern void hev_socks5_tunnel_quit(void);

// hev_socks5_tunnel_quit() blocks forever until some hev exists, and then
// quits whichever one does. Both are hazards: quitting before hev starts hangs
// the caller, and a call left blocked kills the NEXT hev in the process. So
// quit only while our own hev is known to be running. One tunnel per process,
// hence one flag.
static atomic_bool hev_ready;
// Set when the forwarder dies. hev can be healthy while the bridge is not,
// which would report a started tunnel that carries nothing, so startup
// checks this. Session-scoped: cleared when a bridge starts.
static atomic_bool forwarder_failed;

// utun datagrams carry a four-byte, network-order address-family prefix.
// One packet per direction bounds memory and applies backpressure rather than
// building an unbounded queue in a memory-limited Network Extension.
#define FRAME_CAPACITY (4 + 65535)
struct packet {
    unsigned char bytes[FRAME_CAPACITY];
    size_t length;
};

struct vless_packet_bridge {
    int tunnel;
    int sockets[2];
    int wake[2];
    pthread_t thread;
    atomic_bool stopping;
    atomic_uint_fast64_t dropped_ipv6;
    int error; // Written by the worker, read only after pthread_join.
    struct packet to_hev;
    struct packet to_tunnel;
};

static bool prepare_fd(int fd)
{
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 &&
           fcntl(fd, F_SETFD, FD_CLOEXEC) == 0;
}

static void close_bridge(struct vless_packet_bridge *bridge)
{
    int fds[] = { bridge->tunnel, bridge->sockets[0], bridge->sockets[1],
                  bridge->wake[0], bridge->wake[1] };
    for (size_t i = 0; i < sizeof(fds) / sizeof(fds[0]); ++i)
        if (fds[i] >= 0)
            close(fds[i]);
    free(bridge);
}

static bool transient_error(void)
{
    return errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK;
}

// Fail closed for malformed frames and IPv6, in BOTH directions. Filtering
// before hev sees the packet is essential; an Xray blackhole is too late.
static bool accept_ipv4(struct vless_packet_bridge *bridge, struct packet *packet)
{
    if (packet->length < 5)
        return false;
    uint32_t family;
    memcpy(&family, packet->bytes, sizeof(family));
    unsigned int version = packet->bytes[4] >> 4;
    if (ntohl(family) == AF_INET6 || version == 6) {
        atomic_fetch_add(&bridge->dropped_ipv6, 1);
        return false;
    }
    return ntohl(family) == AF_INET && version == 4 && packet->length >= 24;
}

static bool read_packet(struct vless_packet_bridge *bridge, int fd, struct packet *packet)
{
    ssize_t count = read(fd, packet->bytes, sizeof(packet->bytes));
    if (count < 0)
        return transient_error();
    // A zero-length datagram is legal, not stream EOF. Treat it like any
    // other malformed frame; poll handles descriptor errors and hangups.
    packet->length = (size_t)count;
    if (!accept_ipv4(bridge, packet))
        packet->length = 0;
    return true;
}

static bool write_packet(struct vless_packet_bridge *bridge, int fd, struct packet *packet)
{
    ssize_t count = write(fd, packet->bytes, packet->length);
    if (count < 0) {
        if (errno == ENOBUFS) {
            // Darwin may report a full datagram queue as ENOBUFS even while
            // poll says writable. Retain the packet without spinning the CPU.
            struct pollfd wake = { .fd = bridge->wake[0], .events = POLLIN };
            poll(&wake, 1, 1);
            return true;
        }
        return transient_error();
    }
    if ((size_t)count != packet->length) {
        errno = EIO; // A partial datagram cannot be retried as another packet.
        return false;
    }
    packet->length = 0;
    return true;
}

static void *forward_packets(void *context)
{
    struct vless_packet_bridge *bridge = context;
    while (!atomic_load(&bridge->stopping)) {
        struct pollfd fds[] = {
            { .fd = bridge->wake[0], .events = POLLIN },
            { .fd = bridge->tunnel,
              .events = (bridge->to_hev.length ? 0 : POLLIN) |
                        (bridge->to_tunnel.length ? POLLOUT : 0) },
            { .fd = bridge->sockets[0],
              .events = (bridge->to_tunnel.length ? 0 : POLLIN) |
                        (bridge->to_hev.length ? POLLOUT : 0) },
        };
        int count = poll(fds, 3, -1);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (atomic_load(&bridge->stopping) || fds[0].revents)
            return NULL;
        if ((fds[1].revents | fds[2].revents) & (POLLERR | POLLHUP | POLLNVAL)) {
            errno = EIO;
            break;
        }
        if ((fds[1].revents & POLLOUT) && !write_packet(bridge, bridge->tunnel, &bridge->to_tunnel))
            break;
        if ((fds[2].revents & POLLOUT) && !write_packet(bridge, bridge->sockets[0], &bridge->to_hev))
            break;
        if ((fds[1].revents & POLLIN) && !read_packet(bridge, bridge->tunnel, &bridge->to_hev))
            break;
        if ((fds[2].revents & POLLIN) && !read_packet(bridge, bridge->sockets[0], &bridge->to_tunnel))
            break;
    }
    if (atomic_load(&bridge->stopping))
        return NULL;
    bridge->error = errno ? errno : EIO;
    atomic_store(&forwarder_failed, true);
    // An I/O failure must tear down hev too. Retry the wakeup: the first
    // failure can race hev initializing its quit event fd. Bounded at ~5s so a
    // hev that honours quit late cannot pin this thread at 100 Hz forever.
    //
    // KNOWN GAP, needs a design decision rather than a patch here.
    // hev_socks5_tunnel_quit() blocks forever when hev has not started
    // (measured), so a forwarder that fails before hev initializes never
    // returns from the first call: the thread leaks and stop()'s pthread_join
    // hangs teardown. Two fixes were tried and are worse:
    //   - closing hev's descriptor does not stop it (measured: alive >5s);
    //   - quitting on a detached thread unblocks later and kills the NEXT
    //     hev in the process, so a failed session breaks the next connect
    //     (measured: it killed the real-hev test that ran after it).
    // The workable shape is to gate this on hev readiness, which the Swift
    // lifecycle already tracks, rather than guessing from inside the bridge.
    // Only once hev is up, and only while it is: quitting earlier never
    // returns, and the retry window lets a hev that is still starting become
    // ready. If it never does, give up rather than pin the thread — stop()
    // joins it, and the Swift teardown quits hev when it is safe to.
    for (int attempt = 0; attempt < 500 && !atomic_load(&bridge->stopping); ++attempt) {
        if (atomic_load(&hev_ready)) {
            hev_socks5_tunnel_quit();
            break;
        }
        struct pollfd wake = { .fd = bridge->wake[0], .events = POLLIN };
        poll(&wake, 1, 10);
    }
    return NULL;
}

struct vless_packet_bridge *vless_packet_bridge_start(int tunnel_fd)
{
    struct vless_packet_bridge *bridge = calloc(1, sizeof(*bridge));
    if (!bridge)
        return NULL;
    bridge->tunnel = -1;
    bridge->sockets[0] = bridge->sockets[1] = -1;
    bridge->wake[0] = bridge->wake[1] = -1;
    atomic_init(&bridge->stopping, false);
    atomic_store(&hev_ready, false);
    atomic_store(&forwarder_failed, false);
    atomic_init(&bridge->dropped_ipv6, 0);
    // Borrow the provider's utun for the session; never close its original fd.
    // dup shares file-status flags: prepare_fd sets O_NONBLOCK on the original
    // utun too, just as hev did when reading it directly. FD_CLOEXEC applies
    // only to our duplicate. Do not restore shared status flags during cleanup.
    bridge->tunnel = dup(tunnel_fd);
    if (bridge->tunnel < 0 || socketpair(AF_UNIX, SOCK_DGRAM, 0, bridge->sockets) < 0 ||
        pipe(bridge->wake) < 0)
        goto fail;
    // Darwin's Unix datagram defaults fit only two MTU-sized packets. Hev can
    // emit a full TCP window without yielding; ENOBUFS on its write side can
    // stall that flow. Reserve bounded queues for bursts in either direction.
    // This also permits a full-size IP datagram, above the default 2 KiB limit.
    const int socket_capacity = 256 * 1024;
    for (size_t i = 0; i < 2; ++i)
        if (setsockopt(bridge->sockets[i], SOL_SOCKET, SO_SNDBUF,
                       &socket_capacity, sizeof(socket_capacity)) < 0 ||
            setsockopt(bridge->sockets[i], SOL_SOCKET, SO_RCVBUF,
                       &socket_capacity, sizeof(socket_capacity)) < 0)
            goto fail;
    int fds[] = { bridge->tunnel, bridge->sockets[0], bridge->sockets[1],
                  bridge->wake[0], bridge->wake[1] };
    for (size_t i = 0; i < sizeof(fds) / sizeof(fds[0]); ++i)
        if (!prepare_fd(fds[i]))
            goto fail;
    int error = pthread_create(&bridge->thread, NULL, forward_packets, bridge);
    if (error) {
        errno = error;
        goto fail;
    }
    return bridge;
fail: {
    int error = errno;
    close_bridge(bridge);
    errno = error;
    return NULL;
}
}

int vless_packet_bridge_descriptor(const struct vless_packet_bridge *bridge)
{
    return bridge->sockets[1];
}

uint64_t vless_packet_bridge_dropped_ipv6(const struct vless_packet_bridge *bridge)
{
    return atomic_load(&bridge->dropped_ipv6);
}

int vless_packet_bridge_stop(struct vless_packet_bridge *bridge)
{
    atomic_store(&bridge->stopping, true);
    unsigned char byte = 1;
    // Non-blocking: a pending wakeup already makes the pipe readable.
    while (write(bridge->wake[1], &byte, 1) < 0 && errno == EINTR) {}
    pthread_join(bridge->thread, NULL);
    int error = bridge->error;
    close_bridge(bridge);
    return error;
}

static int find_utun(void)
{
    // Same kernel-control lookup as Tun2SocksKit; do not depend on
    // NEPacketTunnelFlow's private socket.fileDescriptor KVC property.
    struct vless_ctl_info info = { 0 };
    strlcpy(info.name, "com.apple.net.utun_control", sizeof(info.name));
    for (int fd = 0; fd <= 1024; ++fd) {
        struct vless_sockaddr_ctl address = { 0 };
        socklen_t length = sizeof(address);
        if (getpeername(fd, (struct sockaddr *)&address, &length) != 0 ||
            address.family != AF_SYSTEM)
            continue;
        if (!info.id && ioctl(fd, VLESS_CTLIOCGINFO, &info) != 0)
            continue;
        if (address.id == info.id)
            return fd;
    }
    errno = ENODEV;
    return -1;
}

int vless_ipv4_socks5_run(const char *config, size_t config_length)
{
    int tunnel = find_utun();
    if (tunnel < 0)
        return -1000 - errno;
    return vless_ipv4_socks5_run_on_descriptor(config, config_length, tunnel);
}

int vless_ipv4_socks5_run_on_descriptor(const char *config, size_t config_length, int tunnel_fd)
{
    if (config_length > UINT_MAX)
        return -1000 - EINVAL;
    struct vless_packet_bridge *bridge = vless_packet_bridge_start(tunnel_fd);
    if (!bridge)
        return -1000 - errno;
    // Ready from here: hev main is being entered, so a quit can only block for
    // as long as its initialization takes, never forever. Set before the call
    // because it does not return until hev stops.
    atomic_store(&hev_ready, true);
    int result = hev_socks5_tunnel_main_from_str((const unsigned char *)config,
                                               (unsigned int)config_length,
                                               vless_packet_bridge_descriptor(bridge));
    // hev has returned; a later quit would land on whatever starts next.
    atomic_store(&hev_ready, false);
    int error = vless_packet_bridge_stop(bridge);
    return error ? -1000 - error : result;
}

int vless_ipv4_socks5_forwarder_failed(void)
{
    return atomic_load(&forwarder_failed) ? 1 : 0;
}

void vless_ipv4_socks5_quit(void)
{
    // Same rule as the bridge's error path: before hev is up this never
    // returns, and teardown would hang behind it.
    if (atomic_load(&hev_ready))
        hev_socks5_tunnel_quit();
}

#include "VlessPacketBridge.h"
#include "VlessHevRuntime.h"

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

// hev has process-wide globals: reject overlapping runs, and protect the active
// bridge's lifetime while a provider asks it to stop. The forwarding thread uses
// its own runtime, so an old/standalone bridge can never stop another session.
static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t active_lock = PTHREAD_MUTEX_INITIALIZER;
static struct vless_packet_bridge *active_bridge;
// Set when the forwarder dies. hev can be healthy while the bridge is not,
// which would report a started tunnel that carries nothing, so startup
// checks this. Session-scoped: cleared when a managed run registers.
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
    atomic_bool failed;
    struct vless_hev_runtime runtime;
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
    vless_hev_runtime_destroy(&bridge->runtime);
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
    atomic_store(&bridge->failed, true);
    pthread_mutex_lock(&active_lock);
    if (active_bridge == bridge)
        atomic_store(&forwarder_failed, true);
    pthread_mutex_unlock(&active_lock);
    // Queue during init, notify once after init, or do nothing after cleanup.
    // This never waits for an event socket belonging to a future session.
    vless_hev_runtime_request_stop(&bridge->runtime);
    return NULL;
}

struct vless_packet_bridge *vless_packet_bridge_start(int tunnel_fd)
{
    struct vless_packet_bridge *bridge = calloc(1, sizeof(*bridge));
    if (!bridge)
        return NULL;
    int runtime_error = vless_hev_runtime_init(&bridge->runtime);
    if (runtime_error) {
        free(bridge);
        errno = runtime_error;
        return NULL;
    }
    bridge->tunnel = -1;
    bridge->sockets[0] = bridge->sockets[1] = -1;
    bridge->wake[0] = bridge->wake[1] = -1;
    atomic_init(&bridge->stopping, false);
    atomic_init(&bridge->failed, false);
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

int vless_packet_bridge_failed(const struct vless_packet_bridge *bridge)
{
    return atomic_load(&bridge->failed) ? 1 : 0;
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
    return vless_ipv4_socks5_run_with_stop_check(config, config_length, NULL, NULL);
}

int vless_ipv4_socks5_run_with_stop_check(const char *config, size_t config_length,
                                        vless_socks5_stop_check stop_check, void *context)
{
    int tunnel = find_utun();
    if (tunnel < 0)
        return -1000 - errno;
    return vless_ipv4_socks5_run_on_descriptor_with_stop_check(
        config, config_length, tunnel, stop_check, context);
}

int vless_ipv4_socks5_run_on_descriptor(const char *config, size_t config_length, int tunnel_fd)
{
    return vless_ipv4_socks5_run_on_descriptor_with_stop_check(
        config, config_length, tunnel_fd, NULL, NULL);
}

int vless_ipv4_socks5_run_on_descriptor_with_stop_check(
    const char *config, size_t config_length, int tunnel_fd,
    vless_socks5_stop_check stop_check, void *context)
{
    if (config_length > UINT_MAX)
        return -1000 - EINVAL;
    int lock_error = pthread_mutex_trylock(&run_lock);
    if (lock_error)
        return -1000 - lock_error;
    struct vless_packet_bridge *bridge = vless_packet_bridge_start(tunnel_fd);
    if (!bridge) {
        int error = errno;
        pthread_mutex_unlock(&run_lock);
        return -1000 - error;
    }
    pthread_mutex_lock(&active_lock);
    active_bridge = bridge;
    atomic_store(&forwarder_failed, atomic_load(&bridge->failed));
    pthread_mutex_unlock(&active_lock);
    // Registration precedes this check: a stop racing the provider's earlier
    // Swift check is either observed here or delivered to this active runtime.
    // Call outside our locks so the caller may safely inspect its own lifecycle.
    if (stop_check && stop_check(context))
        vless_hev_runtime_request_stop(&bridge->runtime);
    int result = vless_hev_runtime_run(&bridge->runtime,
        (const unsigned char *)config, (unsigned int)config_length,
        vless_packet_bridge_descriptor(bridge));
    pthread_mutex_lock(&active_lock);
    active_bridge = NULL;
    pthread_mutex_unlock(&active_lock);
    int error = vless_packet_bridge_stop(bridge);
    if (error)
        atomic_store(&forwarder_failed, true);
    pthread_mutex_unlock(&run_lock);
    return error ? -1000 - error : result;
}

int vless_ipv4_socks5_forwarder_failed(void)
{
    return atomic_load(&forwarder_failed) ? 1 : 0;
}

void vless_ipv4_socks5_quit(void)
{
    pthread_mutex_lock(&active_lock);
    if (active_bridge)
        vless_hev_runtime_request_stop(&active_bridge->runtime);
    pthread_mutex_unlock(&active_lock);
}

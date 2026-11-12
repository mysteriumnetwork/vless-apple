# Review of branch update and IPv6/DNS comparison

This review covers the lifecycle changes in `7499ed9` and `62ef24d`, together
with IPv4 pin validation, zero-length datagram handling, bounded socket buffers
and the full TCP payload regression. The measurements in the [iPhone profile
notes](device-profile-2026-11-12.md) predate those two lifecycle commits.

The initialization-failure finding below remains open. The passing native tests
and iOS build do not establish that this failure path is safe, or that a pure
DNS64/NAT64 network is supported.

## Blocking finding in the pulled commit

`hev_ready` is set immediately before `hev_socks5_tunnel_main_from_str`, not after
hev's quit event descriptor has been initialized. If initialization fails while
the forwarder sees an I/O error, the forwarder can enter the blocking quit call
while the flag is true. Clearing the flag after main returns cannot release that
call; `vless_packet_bridge_stop` then blocks joining the forwarder. The retry
count does not bound time spent inside quit.

Confirmed on the unmodified `62ef24d` C source, linked to the pinned hev archive:

- An open socketpair plus invalid YAML returns `-1` in about 0.4 seconds.
- Closing the peer before the same invalid-YAML start hangs, reaching the
  isolated subprocess's two-second timeout. The merged working tree reproduced
  the same hang. Reproducer subprocesses were terminated after the timeout.

An actual initialization-ready signal and a safe stop API are needed; entering
main is insufficient. This remains an open finding, not an implemented fix.

A minimal reproducer is below. Link it with `VlessPacketBridge.c` and the pinned
macOS hev archive from Tun2SocksKit 5.15.0. Run each case in a separate subprocess
with an external timeout: invoking the failure case inside the test runner
would hang the runner itself.

```c
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include "VlessPacketBridge.h"

int main(int argc, char **argv) {
    int fd[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, fd)) return 2;
    if (argc == 1) close(fd[1]); // No argument: fail the forwarding socket.
    const char *config = "tunnel: [invalid";
    int result = vless_ipv4_socks5_run_on_descriptor(
        config, strlen(config), fd[0]);
    printf("returned %d\n", result);
    close(fd[0]);
    if (argc > 1) close(fd[1]);
    return 0;
}
```

The original two-second timeout proves the call fails to return promptly. The
pinned quit implementation waits until its event descriptor exists, so failed
initialization leaves that wait without a completion condition. The existing
teardown test where hev was never entered does not exercise this race.

## DNS verification against the published Xray library

The shipped macOS XRay archive reports version `26.3.27`. Real DNS messages were
sent through its SOCKS inbound to the `dns` outbound, with the same port-53 rule
and `queryStrategy` policy as Dart. Only the upstream resolver was replaced by a
local controlled DNS server; no public DNS or VLESS server was required.

| Policy | UDP/TCP AAAA result | Upstream AAAA query |
| --- | --- | --- |
| Current `UseIPv4` | NOERROR, zero answers | None |
| `UseIP` control | NOERROR, one AAAA answer | Present (then cached) |
| `UseIP` plus suggested `dns.rules` | Same as UseIP | Present |

A queries return their controlled IPv4 answer. HTTPS (type 65) queries return
REFUSED with zero answers in the shipped core, rather than the silent `drop`
claimed by the current Dart comment. The suggested newer `dns.rules` syntax is
ignored by this core version; adding it is not an effective hardening change
without changing the shipped core. Thus the raw A/AAAA port-53 gap does not
exist in our current configuration. DoH/DoT and independently obtained IPv6 addresses
still bypass that DNS path; this is why the packet filter remains useful.

Evidence: `/private/tmp/vless-public-review/dns_probe.py`, `dns-results-*.json`.
Pinned source: [DNS outbound](https://github.com/XTLS/Xray-core/blob/v26.3.27/proxy/dns/dns.go)
and [built-in resolver](https://github.com/XTLS/Xray-core/blob/v26.3.27/app/dns/dns.go).

## IPv6-only underlay and prior art

The provider resolves the physical proxy endpoint with `AF_INET`, and its local
pinning guard requires an IPv4 literal. Pure DNS64/NAT64 connectivity needs
separate validation and transport-family handling; these are independent of
whether app destinations may use IPv6 through the exit. Merely advertising the
TUN's IPv6 DNS address is insufficient here: the C bridge deliberately discards
all IPv6, including those DNS packets. Hiddify can advertise that address because
its stack intercepts DNS to it. Do not copy that setting without implementing
and validating the matching packet path.

The quoted flutter_vless policy and explicit AAAA-return rule are present in
older revision `b61e33c425058f01c8d2b42118726d3df75553f0`. The IPv6 policy changed
on October 19 in `aeae2c0`/`605853d`; current source captures IPv6 without inserting
that old library blackhole rule. Therefore the quoted comments do not describe
current main. A statement about measured dual-stack support is not proof that
our IPv4-only dropping bridge implements dual-stack forwarding.

Hiddify's current documentation describes rejecting disallowed IPv6 before the
handshake and per-proxy verification/fallback. It corroborates the failure mode,
but does not support claiming that neither project solves it before acceptance.

Primary references:

- [Older flutter_vless DNS policy](https://github.com/XIIIFOX/flutter_vless/blob/b61e33c425058f01c8d2b42118726d3df75553f0/ios/flutter_vless/Sources/flutter_vless_tunnel_support/TunnelDNSPolicy.swift)
- [Later flutter_vless IPv6 policy](https://github.com/XIIIFOX/flutter_vless/blob/605853dface4c216e7ba677631c98c73c601b7fa/ios/flutter_vless/Sources/flutter_vless_tunnel_support/TunnelIPv6Policy.swift)
- [Hiddify core policy](https://hiddify.com/core/sing-box/app_considerations/)
- [Hiddify iOS DNS settings](https://github.com/hiddify/hiddify-app/blob/main/ios/HiddifyPacketTunnel/SingBox/ExtensionPlatformInterface.swift)
- [Apple DNS64/NAT64 guidance](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/NetworkingOverview/UnderstandingandPreparingfortheIPv6Transition/UnderstandingandPreparingfortheIPv6Transition.html)

## Validation

The updated branch plus the local fixes passes 39 native tests and an unsigned
arm64 iOS build. The earlier signed iPhone build and performance results are
recorded separately in the profile notes. The new unstarted-hev teardown test covers the no-start case, not failed initialization.
The initialization-failure repro above is run in a separate bounded subprocess
so a hang cannot wedge the suite. No further phone session was started; the
previous iPhone measurements predate these two incoming lifecycle commits.

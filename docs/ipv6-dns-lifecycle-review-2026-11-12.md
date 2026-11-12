# Review of branch update and IPv6/DNS comparison

This review covers the lifecycle changes in `7499ed9` and `62ef24d`, together
with IPv4 pin validation, zero-length datagram handling, bounded socket buffers
and the full TCP payload regression. The measurements in the [iPhone profile
notes](device-profile-2026-11-12.md) predate those two lifecycle commits.

The initialization-failure hang described below is fixed by the phased runtime.
Pure DNS64/NAT64 underlay support remains unvalidated; this lifecycle fix does
not change the IPv4 pinning or packet policy.

## Initialization-failure teardown: resolved

`VlessHevRuntime.c` now calls the pinned archive's separate initialization,
run and cleanup exports instead of its monolithic `main_from_str`. It marks
readiness only after `hev_socks5_tunnel_init` succeeds. A bridge owns its own
stop request and one-shot quit state; a stop during initialization is queued
rather than waiting for an event descriptor that might never exist.

The runtime mutex serializes quit with descriptor destruction. Cleanup clears
readiness under that mutex before closing the event socket. The active bridge
is protected while the provider requests stop, and process-wide initialization
is exclusive: a second run returns `-1000 - EBUSY` without touching the first.
A standalone bridge's failure cannot stop the managed session. There are no
quit retry workers or detached callers that can wake up in a later session.

The provider also passes a cancellation check at C entry. Registration happens
before that check: a stop racing the earlier Swift check is either seen there
or queued against the registered runtime. The callback is synchronous and its
context remains retained by the provider's worker closure until run returns.

This avoids a new binary, but depends on 27 private exports from the exact
Tun2SocksKit 5.15.0 / hev 2.15.0 archive. `HevPinnedABI.h` lists the signatures;
the init/unwind sequence follows pinned `src/hev-main.c`. Changing that pin
requires revalidating the ABI and lifecycle. The simulator archive has only
nonfunctional public stubs, so its original failure behavior is retained.

### Historical failure and reproducer

In `62ef24d`, `hev_ready` is set immediately before `hev_socks5_tunnel_main_from_str`, not after
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

The fix uses successful tunnel initialization as the readiness signal and
serializes stop against cleanup. The same failure cases now return promptly;
they no longer enter the pinned stop API while its event descriptor is absent.

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

On the old implementation, the two-second timeout demonstrated failure to
return promptly. The pinned quit implementation waits until its event
descriptor exists, so failed initialization leaves that wait without a
completion condition. Against the fixed runtime, the reproducer returns an
initialization or forwarding error. The new subprocess regressions cover this
race, not just the earlier no-start case.

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

- All 43 native tests pass, including the full 512 KiB transfer and IPv6 filter.
- Four real-hev lifecycle regressions run in separate macOS XCTest subprocesses
  with an eight-second parent timeout. A regression is killed and reported as a
  failure rather than wedging CI or contaminating later tests with lwIP globals.
- Failed initialization is repeated 32 times with a failed forwarding socket,
  followed by logger-init failure and three successful start/stop sessions.
- A FIFO blocks initialization before its event socket exists. Stop requests
  must return promptly, then complete once init is allowed to finish.
- Late cancellation skips parsing; overlapping runs and an unrelated bridge's
  failure leave the active session healthy. Duplicate concurrent stops are safe.
- Required private symbols are present in iOS arm64 and both Mac architectures.
  Device, simulator and Intel Mac C link probes pass against the unchanged
  archive. Native iOS and simulator package builds succeed.
- C warnings-as-errors and static analysis pass. The earlier signed iPhone
  performance runs predate this fix and were not repeated; data-plane filtering
  and buffer limits are unchanged.

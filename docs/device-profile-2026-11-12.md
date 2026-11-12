# VLESS IPv4 packet bridge: iPhone validation, 2026-11-12

## Scope and method

- Device: iPhone 15 Pro Max, iOS 27.3 (24C5037i).
- Xcode 27.2; signed Profile app and packet tunnel extension.
- Baseline: native commit `add4b33` (direct utun, before this PR).
- Measured bridge: `77b007b` plus the local review fixes and bounded socket-buffer adjustment, before the later lifecycle commits `7499ed9` and `62ef24d`. The device measurements were not repeated after those commits were pulled.
- Same example app, VLESS endpoint and exit (`217.154.26.105`) and Wi-Fi. CPU was recorded with USB power; the separate power runs were unplugged and used wireless profiling.
- A temporary app copy disables the foreground idle timer. Repository app code and system auto-lock settings were not changed.
- Each pass checks an IPv6 TCP destination and downloads the complete Google gstatic JS resource, then waits 30 seconds, downloads HTTPS data paced at 7,400,000 bytes/s for 45 seconds, waits 15 seconds and disconnects.
- Instruments Time Profiler records all processes; results below include only `XrayTunnel`. The all-process trace emitted symbol-overlap warnings for unrelated system/application images; these CPU totals use process samples, not symbol-attributed function costs. CPU is sampled percent of one core. Steady windows exclude startup and the edges of the traffic phase. Footprint comes from the extension's physical-footprint metric every two seconds.

## Forwarding defect found during validation

The original bridge's Unix datagram sockets used Darwin defaults: a 2 KiB send limit and a receive queue holding only two full-sized packets. Real hev can emit a TCP-window burst without yielding. Its write path reports `ENOBUFS` as an interface error rather than ordinary backpressure, and a transfer can stall.

This reproduced on the awake iPhone: the gstatic body stalled and hev logged failed tunnel writes. A local real-hev TCP test also stalled before receiving all 512 KiB. Both completed after reserving bounded 256 KiB send and receive buffers on both bridge sockets. The native regression now verifies the whole TCP payload; the original queues fail that regression.

The bounded queues accommodate the tested bursts and workloads. They do not guarantee recovery from arbitrary concurrent overload.

## Device results

Both builds transferred the complete gstatic script (HTTP 200, 264,754 bytes)
and sustained 59.2 Mbps of HTTP body data for 45 seconds through the same exit.
The baseline falsely completed the IPv6 TCP handshake in 1 ms. The fixed bridge
allowed no IPv6 TCP connection; the explicit IPv6-only probe timed out at 3 s.

The paired CPU recording remained at **Fair** thermal state throughout. Idle
windows were 20 seconds; steady-load windows were 35 seconds.

| Metric | Direct utun baseline | Fixed bridge |
| --- | ---: | ---: |
| Idle CPU, % of one core | 1.46% | 1.37% |
| Download CPU, % of one core | 33.21% | 40.96% |
| Load footprint, MiB range | 22.30–23.24 | 19.13–20.86 |
| Tunnel downlink including IP overhead | 61.07 Mbps | 61.09 Mbps |
| Tunnel uplink (mostly acknowledgements) | 0.45 Mbps | 0.85 Mbps |

The observed CPU increase is **7.75 percentage points of one core**, or 23.3%
relative to the baseline CPU use. Throughput was maintained at the tested rate.
Memory ranges are observations of these sessions; Go allocation and collection
vary, so they do not establish a memory reduction. Socket queue reservations
are bounded separately from the process-level footprint measurement.

Wireless power was recorded separately after USB was disconnected, using a
Blank Instruments template with only Power Profiler, targeting all processes.
Both valid runs remained **Nominal** thermally and reported 100% screen
brightness. The same 20-second idle and 35-second steady-load windows were used.

| Whole-phone power, battery energy per hour | Baseline | Fixed bridge |
| --- | ---: | ---: |
| Idle, weighted mean | 12.63%/h | 12.28%/h |
| Download, weighted mean | 15.61%/h | 16.82%/h |
| Download, sample median | 15.10%/h | 15.91%/h |

The observed load difference is **+1.21 percentage points of battery energy per
hour** for the whole phone. These short, separate runs include the display,
network, foreground download app, wireless profiling and background activity.
They do not isolate extension power or establish long-term battery endurance.
The per-second load samples also varied (baseline 14.38–23.26%/h; fixed
15.33–23.97%/h), so do not treat the mean difference as a precise battery penalty.

## Evidence

Local Instruments artifacts (not committed, because the CPU capture includes
other processes):

- `/private/tmp/vless-device-profile/paired-cpu-final.trace`
- `/private/tmp/vless-device-profile/paired-baseline-summary.json`
- `/private/tmp/vless-device-profile/paired-patched-summary.json`
- `/private/tmp/vless-device-profile/wireless-baseline-final-cpu.trace`
- `/private/tmp/vless-device-profile/wireless-patched-final-cpu.trace`
- `/private/tmp/vless-device-profile/wireless-baseline-power-summary.json`
- `/private/tmp/vless-device-profile/wireless-patched-power-summary.json`

The ordinary example app with the fixed bridge was restored after testing.
The performance driver and keep-awake changes exist only in temporary test
copies; the test VPN was disconnected and no profiler was left recording.

## Remaining validation limits

- These are short runs on one device and one exit. The workload exercises downloads and their upload acknowledgements, not sustained upload or broad concurrency.
- The IPv6-only socket must time out before TCP connects. The gstatic HTTP request checks normal automatic resolution; this is not a Safari/Chrome DoH or a complete browser navigation test.
- The app-targeted Power Profiler template did not include the extension as a CPU target. Its system power readings while USB-powered were zero, so those traces cannot establish battery cost. Apple documents zero overall system power while charging and recommends wireless debugging for that metric: [Power Profiler documentation](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler). A short unplugged power comparison is included above; longer endurance and repeatability testing remain open.
- Preserve the IPv4 DNS fix. Silent IPv6 dropping is a complementary safeguard and may add a connection-racing delay if AAAA addresses still reach an application.

## Build and regression validation

- At profiling time, 38 native tests passed, including real-hev IPv6 suppression, a complete 512 KiB IPv4 TCP payload, and bridge I/O failure propagation.
- The expanded real-hev regression fails against the original small queues and passes with the buffer adjustment.
- At profiling time, the signed arm64 iPhone build, C warnings-as-errors and diff whitespace checks passed. The later branch validation is recorded in the review notes.
- Profiling did not publish a release or change production. Subsequent branch integration and review findings are described in the [DNS and lifecycle review](ipv6-dns-lifecycle-review-2026-11-12.md).

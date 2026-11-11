# vless-apple

The Apple packet-tunnel engine for VLESS: a trimmed [Xray-core][xray] and
[hev-socks5-tunnel][hev], packaged as a SwiftPM library for iOS and macOS.

Consumed by a packet tunnel extension target. The Flutter plugin that drives it
lives in [vless_dart][plugin]; this package deliberately knows nothing about
Flutter, because an extension that links Flutter is killed by the iOS memory
limit.

## Usage

Add the package, then link **`vless-tunnel-support`** to the *extension* target
only — never to the app. Subclass the provider:

```swift
import vless_tunnel_support

class PacketTunnelProvider: VlessPacketTunnelProvider {}
```

Name that class as `NSExtensionPrincipalClass` in the extension's Info.plist,
and give it the `packet-tunnel-provider` Network Extension entitlement (plus
App Sandbox with network client and server on macOS).

## How it works

The app hands the extension an Xray JSON config. The provider picks a free
loopback port, mints per-session SOCKS credentials, starts Xray, then starts
hev-socks5-tunnel to move packets between the system tunnel interface and that
SOCKS inbound. IPv4 and IPv6 are both captured so neither leaks around the
tunnel.

## Development

```sh
make check        # swift build + swift test + go test
make build-core   # gomobile bind for iOS + macOS, merged and verified
make clean-core   # drop the local build, go back to the published release
swift test        # no Xcode project, no signing
```

`LOCAL_CORE=1` links a locally built core instead of the published release —
required when changing `third_party/xray-mobile`. It is an environment variable
rather than a check for the artifact on disk because SwiftPM caches manifest
evaluation and only re-runs it when the manifest's contents or environment
change; a disk check would be served stale.

The feature set is `third_party/xray-mobile/distro.go` — editing that file is
how a protocol or transport gets added, and it is deliberately a visible,
reviewable change.

### Publishing a new core

The artifact is ~59 MB and rebuilt on every Xray bump, so it is not committed.

1. Commit the change to `third_party/xray-mobile` or to the build script.
2. Tag **that commit** `xray-v<version>` and push the tag. The *Release Xray
   core* workflow builds and publishes it.
3. Copy the `url` and `checksum` from the job summary into the `binaryTarget`
   in `Package.swift`, and commit that.

The workflow builds the tagged tree, not your working copy — tagging a commit
that predates the change republishes the old core, and the run still goes green.

`build_xray_apple.sh` guards the two defects that are otherwise invisible until
a device rejects the build: it checks every slice's deployment target against
`IOS_VERSION`/`MACOS_VERSION`, and it checks the xcframework is library-form.
A `-framework` xcframework gets embedded into the app bundle by Xcode even
though it wraps a static archive, and the iOS install then fails to codesign it.

## Licensing

MIT; see [LICENSE](LICENSE). Third-party components and their terms are in
[NOTICE](NOTICE).

[xray]: https://github.com/XTLS/Xray-core
[hev]: https://github.com/heiher/hev-socks5-tunnel
[plugin]: https://github.com/mysteriumnetwork/vless_dart

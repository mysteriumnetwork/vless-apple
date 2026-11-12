// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Trimmed Xray core — VLESS over WebSocket + TLS only, built by
// scripts/build_xray_apple.sh from third_party/xray-mobile.
//
// Shipped as a -library xcframework, never a -framework one. Xcode embeds a
// binary target delivered as a .framework into the app bundle even when it
// wraps a static archive, then fails to codesign the archive and the iOS
// install dies with 0xe8008014. A library is linked and never embedded.
//
// The published release is the default, so a clone needs no Go toolchain. Set
// VLESS_LOCAL_CORE=1 to link a local build instead — required when changing
// third_party/xray-mobile. It must be an environment variable rather than a
// check for the artifact on disk: SwiftPM caches manifest evaluation and only
// re-runs it when the manifest's contents or its environment change, so a disk
// check would be served stale.
let xrayCore: Target
if ProcessInfo.processInfo.environment["VLESS_LOCAL_CORE"] == "1" {
  xrayCore = .binaryTarget(name: "XRay", path: "Artifacts/XRay.xcframework")
} else {
  xrayCore = .binaryTarget(
    name: "XRay",
    url: "https://github.com/mysteriumnetwork/vless-apple/releases/download/xray-v26.3.27-4/XRay.xcframework.zip",
    checksum: "55db7b12631356abdc4e986c98e63eecac9245e5b61827482e4aa93f14b73c3b"
  )
}

let package = Package(
  name: "vless-apple",
  platforms: [
    .iOS("15.0"),
    .macOS("13.0")
  ],
  products: [
    // For a packet tunnel extension target. Deliberately Flutter-free: an
    // extension that links Flutter is killed by the iOS memory limit, and the
    // Go runtime inside the core collides with WireGuard's if both land in one
    // binary.
    .library(name: "vless-tunnel-support", targets: ["vless_tunnel_support"])
  ],
  dependencies: [
    .package(url: "https://github.com/EbrahimTahernejad/Tun2SocksKit", exact: "5.15.0")
  ],
  targets: [
    .target(
      name: "vless_tunnel_support",
      dependencies: [
        "VlessPacketBridge",
        "XRay",
        .product(name: "Tun2SocksKit", package: "Tun2SocksKit"),
        .product(name: "Tun2SocksKitC", package: "Tun2SocksKit")
      ],
      // Go's net package resolves via libresolv (_res_9_ninit et al).
      linkerSettings: [.linkedLibrary("resolv")]
    ),
    .target(name: "VlessPacketBridge"),
    .testTarget(
      name: "vless_tunnel_supportTests",
      dependencies: ["vless_tunnel_support", "VlessPacketBridge"]
    ),
    xrayCore
  ]
)

#!/usr/bin/env bash
#
# Builds the trimmed Xray core as XRay.xcframework for iOS and macOS.
#
# Output goes to darwin/vless_dart/Artifacts/, which Package.swift links only
# under VLESS_LOCAL_CORE=1; otherwise it fetches a published release. The path must stay inside the SwiftPM package: Flutter symlinks
# the package into example/ios/Flutter/ephemeral/Packages/, so a binaryTarget
# path that escapes the package root resolves against that location instead.
#
# Requires full Xcode (not just Command Line Tools) — `gomobile bind -target=ios`
# needs the iphoneos and iphonesimulator SDKs.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/third_party/xray-mobile"
OUT="$ROOT/Artifacts"
IOS_VERSION="${IOS_VERSION:-15.0}"
# Must match Package.swift and the host app. Without it gomobile defaults to
# the host SDK, which stamps objects with a far newer minimum than we claim.
MACOS_VERSION="${MACOS_VERSION:-13.0}"

export PATH="/opt/homebrew/bin:$PATH"
export PATH="$PATH:$(go env GOPATH)/bin"

if ! go version | grep -q 'darwin/arm64'; then
  echo "error: need an arm64 Go toolchain; found: $(go version)" >&2
  echo "  a stale x86_64 Go at /usr/local/go will shadow Homebrew's if PATH order flips" >&2
  exit 1
fi

if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
  echo "error: Xcode must be selected, not Command Line Tools" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

# `gomobile version` reports "binary is out of date" even when bind works, so
# check for the binary rather than trusting its self-report.
command -v gomobile >/dev/null || { echo "error: gomobile not installed" >&2; exit 1; }

WORK="$MODULE/build"
rm -rf "$WORK/ios" "$WORK/mac"
mkdir -p "$WORK/ios" "$WORK/mac" "$OUT"
cd "$MODULE"

# gomobile emits one xcframework per target, and names the inner framework
# after the output file. SwiftPM's binaryTarget takes a single xcframework, and
# -create-xcframework rejects mismatched module names — so both builds must be
# named XRay and then merged.
echo "==> building iOS"
gomobile bind -a -ldflags="-s -w" -target=ios -iosversion="$IOS_VERSION" \
  -o "$WORK/ios/XRay.xcframework" .

echo "==> building macOS"
gomobile bind -a -ldflags="-s -w" -target=macos -macosversion="$MACOS_VERSION" \
  -o "$WORK/mac/XRay.xcframework" .

# gomobile emits each slice as a .framework wrapping a static ar archive. Ship
# it as a -library xcframework instead: Xcode embeds a binary target delivered
# as a .framework into the app bundle even when it is static, then fails to
# codesign the archive ("invalid signature", 0xe8008014) and the iOS install
# dies. A -library xcframework is linked and never embedded.
#
# Headers nest under Headers/XRay/ because they are copied into the shared
# $BUILT_PRODUCTS_DIR/include: Tun2SocksKit already puts a module.modulemap at
# its root, and two at the same path break the build.
repackage_slice() { # <gomobile-xcframework> <slice>
  local src="$1/$2/XRay.framework" dst="$WORK/lib/$2"
  mkdir -p "$dst/Headers/XRay"
  cp "$src/Headers/"*.h "$dst/Headers/XRay/"
  cp "$src/XRay" "$dst/libXRay.a"
  # The framework module map gomobile writes is not usable outside a framework.
  {
    echo "module XRay {"
    for h in ref.h XRay.objc.h Universe.objc.h XRay.h; do echo "    header \"$h\""; done
    echo
    echo "    export *"
    echo "}"
  } > "$dst/Headers/XRay/module.modulemap"
}

echo "==> repackaging slices as a static library"
rm -rf "$WORK/lib" "$OUT/XRay.xcframework"
repackage_slice "$WORK/ios/XRay.xcframework" ios-arm64
repackage_slice "$WORK/ios/XRay.xcframework" ios-arm64_x86_64-simulator
repackage_slice "$WORK/mac/XRay.xcframework" macos-arm64_x86_64

xcodebuild -create-xcframework \
  -library "$WORK/lib/ios-arm64/libXRay.a"                  -headers "$WORK/lib/ios-arm64/Headers" \
  -library "$WORK/lib/ios-arm64_x86_64-simulator/libXRay.a" -headers "$WORK/lib/ios-arm64_x86_64-simulator/Headers" \
  -library "$WORK/lib/macos-arm64_x86_64/libXRay.a"         -headers "$WORK/lib/macos-arm64_x86_64/Headers" \
  -output "$OUT/XRay.xcframework" >/dev/null

echo
echo "==> verifying deployment targets"
# A slice stamped with the wrong minimum links with only a warning and ships a
# core that does not honour the floor Package.swift claims. Fail the build.
verify_slice() {
  local bin="$1" arch="$2" want="$3" got slice
  slice="$(basename "$(dirname "$bin")")"
  got="$(otool -arch "$arch" -l "$bin" | grep -A4 LC_BUILD_VERSION \
         | awk '/minos/{print $2}' | sort -u | tr '\n' ' ')"
  got="${got% }"
  if [ "$got" != "$want" ]; then
    echo "   FAIL $slice ($arch): minos '$got', expected '$want'" >&2
    return 1
  fi
  echo "   ok   $slice ($arch): minos $got"
}

XC="$OUT/XRay.xcframework"
rc=0
verify_slice "$XC/macos-arm64_x86_64/libXRay.a" arm64  "$MACOS_VERSION" || rc=1
verify_slice "$XC/macos-arm64_x86_64/libXRay.a" x86_64 "$MACOS_VERSION" || rc=1
verify_slice "$XC/ios-arm64/libXRay.a" arm64 "$IOS_VERSION" || rc=1
verify_slice "$XC/ios-arm64_x86_64-simulator/libXRay.a" arm64  "$IOS_VERSION" || rc=1
verify_slice "$XC/ios-arm64_x86_64-simulator/libXRay.a" x86_64 "$IOS_VERSION" || rc=1
if [ "$rc" -ne 0 ]; then
  echo "   deployment targets do not match IOS_VERSION/MACOS_VERSION" >&2
  exit 1
fi

echo
echo "==> verifying packaging form"
# A .framework here would be embedded by Xcode and fail to codesign on iOS.
if grep -q FrameworkPath "$XC/Info.plist" || ! grep -q LibraryPath "$XC/Info.plist"; then
  echo "   FAIL xcframework is not library-form; iOS installs would reject it" >&2
  exit 1
fi
echo "   ok   library-form xcframework (never embedded, so nothing to sign)"

echo
echo "==> slices"
ls "$OUT/XRay.xcframework" | grep -v Info.plist | sed 's/^/   /'

echo
echo "==> sizes"
du -sh "$OUT/XRay.xcframework"
du -h "$OUT/XRay.xcframework/ios-arm64/libXRay.a" | sed 's/^/   device slice: /'

echo
echo "==> checksum for a remote binaryTarget"
(cd "$OUT" && rm -f XRay.xcframework.zip \
  && zip -qry XRay.xcframework.zip XRay.xcframework \
  && shasum -a 256 XRay.xcframework.zip | awk '{print "   sha256: "$1}' \
  && rm -f XRay.xcframework.zip)

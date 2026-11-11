.DEFAULT_GOAL := check

# LOCAL_CORE=1 links a locally built Xray core instead of the published
# release. Read by Package.swift; required when changing third_party/xray-mobile.
ifdef LOCAL_CORE
export VLESS_LOCAL_CORE := 1
endif

build:
	swift build

test:
	swift test

test-go:
	cd third_party/xray-mobile && go test ./...

check: build test test-go

# gomobile bind for iOS + macOS, merged into one library xcframework.
build-core:
	./scripts/build_xray_apple.sh

# Drop the local build so SwiftPM goes back to the published release.
clean-core:
	rm -rf Artifacts/XRay.xcframework

.PHONY: build test test-go check build-core clean-core

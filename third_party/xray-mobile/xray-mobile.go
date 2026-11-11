// Package XRay is a gomobile-bindable wrapper around a trimmed Xray-core.
//
// See distro.go for the supported feature set.
package XRay

import (
	"bytes"
	"errors"
	"fmt"
	"runtime/debug"
	"strings"
	"sync"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
)

var (
	mu      sync.Mutex
	running *core.Instance
)

// SetMemoryLimit constrains the Go runtime so Xray fits inside an iOS Network
// Extension, which is jetsam-killed past roughly 50 MB. Call before Start.
func SetMemoryLimit() {
	debug.SetGCPercent(10)
	debug.SetMemoryLimit(30 * 1024 * 1024)
}

// Start boots Xray from a JSON config. Returns an error if one is already up.
func Start(config []byte) error {
	mu.Lock()
	defer mu.Unlock()

	if running != nil {
		return errors.New("xray is already running")
	}

	parsed, err := serial.LoadJSONConfig(bytes.NewReader(config))
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	instance, err := core.New(parsed)
	if err != nil {
		return fmt.Errorf("create instance: %w", err)
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		return fmt.Errorf("start instance: %w", err)
	}

	running = instance
	return nil
}

// Stop shuts Xray down. Safe to call when nothing is running.
func Stop() {
	mu.Lock()
	defer mu.Unlock()

	if running == nil {
		return
	}
	_ = running.Close()
	running = nil
}

// IsRunning reports whether an instance is up.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return running != nil
}

// GetVersion returns the linked Xray-core version.
func GetVersion() string {
	return core.Version()
}

// QueryStats returns the byte counters for an outbound tag, formatted as
// "uplink>>>N\ndownlink>>>N". Empty when Xray is down or the counters are not
// registered. The config must enable statsOutboundUplink/Downlink.
//
// This is a cross-check only; the tun2socks bridge's counters remain the source
// of truth, because they measure what actually crossed the tunnel.
func QueryStats(tag string) string {
	mu.Lock()
	instance := running
	mu.Unlock()

	if instance == nil {
		return ""
	}
	manager, ok := instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok || manager == nil {
		return ""
	}

	var out strings.Builder
	for _, direction := range []string{"uplink", "downlink"} {
		counter := manager.GetCounter("outbound>>>" + tag + ">>>traffic>>>" + direction)
		if counter == nil {
			continue
		}
		fmt.Fprintf(&out, "%s>>>%d\n", direction, counter.Value())
	}
	return out.String()
}

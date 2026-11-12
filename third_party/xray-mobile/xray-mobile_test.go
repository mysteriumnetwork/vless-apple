package XRay

import (
	"io"
	"net"
	"regexp"
	"strings"
	"testing"
	"time"
)

// The exact shape lib/src/xray_config.dart emits, with the placeholder port and
// credentials the tunnel provider fills at startup.
const dartConfig = `{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "1.0.0.1"
    ],
    "queryStrategy": "UseIPv4"
  },
  "stats": {},
  "policy": {
    "system": {
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 10815,
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "u",
            "pass": "p"
          }
        ],
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "supervpn-testnet-01.mysterium.network",
            "port": 443,
            "users": [
              {
                "id": "f7422437-7044-4599-8165-5f7ae7311fc4",
                "encryption": "none",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "supervpn-testnet-01.mysterium.network",
          "allowInsecure": false
        },
        "wsSettings": {
          "path": "/vless",
          "host": "supervpn-testnet-01.mysterium.network"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "dns-out",
      "protocol": "dns",
      "settings": {
        "nonIPQuery": "reject"
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "port": 53,
        "outboundTag": "dns-out"
      }
    ]
  }
}`

// The trimmed distro must register every feature the Dart layer can emit.
// Failing here means distro.go is missing an import.
func TestStartsWithTheConfigDartProduces(t *testing.T) {
	SetMemoryLimit()
	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer Stop()

	if !IsRunning() {
		t.Fatal("expected IsRunning after a successful Start")
	}
}

func TestRejectsMalformedConfig(t *testing.T) {
	if err := Start([]byte("{not json")); err == nil {
		Stop()
		t.Fatal("expected an error for malformed config")
	}
}

// `infra/conf` ships config parsers for every protocol regardless of what
// distro.go registers, so a trimmed-out protocol like vmess still LOADS here —
// it only fails later, at handler construction. A genuinely unknown id is the
// one thing the config layer rejects outright.
//
// The practical consequence: Xray will not catch an unsupported protocol or
// transport for us. VlessUri.parse on the Dart side is the real guard.
func TestRejectsAnUnknownProtocolID(t *testing.T) {
	bogus := strings.Replace(dartConfig, `"protocol": "vless"`, `"protocol": "notarealprotocol"`, 1)
	err := Start([]byte(bogus))
	if err == nil {
		Stop()
		t.Fatal("expected an unknown protocol id to be refused")
	}
	if !strings.Contains(err.Error(), "unknown config id") {
		t.Fatalf("expected an unknown-config-id error, got: %v", err)
	}
}

func TestRefusesConcurrentStart(t *testing.T) {
	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("first Start: %v", err)
	}
	defer Stop()

	if err := Start([]byte(dartConfig)); err == nil {
		t.Fatal("expected the second Start to be refused")
	}
}

func TestGetVersionIsNotEmpty(t *testing.T) {
	if GetVersion() == "" {
		t.Fatal("expected a version string")
	}
}

// The DNS app, the dns outbound and the port-53 rule must survive any future
// trim of distro.go: without them AAAA records reach the client, and an IPv6
// connection through tun2socks fails in a way browsers cannot recover from.
func TestEmittedConfigResolvesIPv4Only(t *testing.T) {
	for _, want := range []string{`"queryStrategy": "UseIPv4"`, `"protocol": "dns"`, `"port": 53`, `"nonIPQuery": "reject"`} {
		if !strings.Contains(dartConfig, want) {
			t.Fatalf("config no longer contains %s", want)
		}
	}

	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("xray refused the config Dart emits: %v", err)
	}
	defer Stop()

	if !IsRunning() {
		t.Fatal("xray reported not running after a successful start")
	}
}

// An AAAA query must come back NOERROR with no answers, not REFUSED: that is
// what lets a client drop straight to the A record. Setting blockTypes on the
// dns outbound returns REFUSED instead, which some stub resolvers treat as a
// dead server — measured, and this test is what keeps it out.
//
// It does NOT prove queryStrategy is doing the masking: with no reachable
// upstream, UseIPv4 and UseIP both answer empty here. That needs a live exit.
func TestAAAAQueryReturnsEmptyNoError(t *testing.T) {
	port := regexp.MustCompile(`"port": (\d+)`).FindStringSubmatch(dartConfig)
	user := regexp.MustCompile(`"user": "([^"]+)"`).FindStringSubmatch(dartConfig)
	pass := regexp.MustCompile(`"pass": "([^"]+)"`).FindStringSubmatch(dartConfig)
	if port == nil || user == nil || pass == nil {
		t.Fatal("fixture no longer carries a socks port and credentials")
	}

	if err := Start([]byte(dartConfig)); err != nil {
		t.Fatalf("xray refused the config: %v", err)
	}
	defer Stop()

	var conn net.Conn
	var err error
	for attempt := 0; attempt < 50; attempt++ {
		conn, err = net.DialTimeout("tcp", "127.0.0.1:"+port[1], time.Second)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("socks inbound never accepted: %v", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	// SOCKS5 with username/password, then CONNECT 1.1.1.1:53. The port-53
	// routing rule hands that to the dns outbound, which answers locally.
	if _, err := conn.Write([]byte{5, 1, 2}); err != nil {
		t.Fatalf("greeting: %v", err)
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatalf("greeting reply: %v", err)
	}
	if reply[1] != 2 {
		t.Fatalf("server chose auth method %d, want 2", reply[1])
	}
	auth := []byte{1, byte(len(user[1]))}
	auth = append(auth, user[1]...)
	auth = append(auth, byte(len(pass[1])))
	auth = append(auth, pass[1]...)
	if _, err := conn.Write(auth); err != nil {
		t.Fatalf("auth: %v", err)
	}
	if _, err := io.ReadFull(conn, reply); err != nil {
		t.Fatalf("auth reply: %v", err)
	}
	if reply[1] != 0 {
		t.Fatalf("auth rejected: %d", reply[1])
	}
	if _, err := conn.Write([]byte{5, 1, 0, 1, 1, 1, 1, 1, 0, 53}); err != nil {
		t.Fatalf("connect: %v", err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 10)); err != nil {
		t.Fatalf("connect reply: %v", err)
	}

	query := []byte{
		0xab, 0xcd, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
		7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0,
		0, 28, // QTYPE AAAA
		0, 1, // QCLASS IN
	}
	if _, err := conn.Write(append([]byte{byte(len(query) >> 8), byte(len(query))}, query...)); err != nil {
		t.Fatalf("write query: %v", err)
	}

	size := make([]byte, 2)
	if _, err := io.ReadFull(conn, size); err != nil {
		t.Fatalf("read length: %v", err)
	}
	answer := make([]byte, int(size[0])<<8|int(size[1]))
	if _, err := io.ReadFull(conn, answer); err != nil {
		t.Fatalf("read answer: %v", err)
	}
	if len(answer) < 8 {
		t.Fatalf("truncated answer: %d bytes", len(answer))
	}
	if rcode := answer[3] & 0x0f; rcode != 0 {
		t.Fatalf("AAAA rcode = %d, want 0 (NOERROR). 5 is REFUSED, which some stub resolvers treat as a dead server", rcode)
	}
	if count := int(answer[6])<<8 | int(answer[7]); count != 0 {
		t.Fatalf("AAAA answer count = %d, want 0", count)
	}
}

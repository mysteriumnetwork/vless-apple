import Foundation
import Security

public enum ProxyCredentialError: Error {
    case entropyUnavailable
    case unusableValue
}

/// Username and password for the loopback SOCKS inbound.
///
/// Minted per session inside the tunnel extension, so the proxy is useless to
/// anything else on the device and the secret never crosses a process boundary.
/// `description` is deliberately opaque: these end up in a config file and must
/// not reach a log through string interpolation.
public struct ProxyCredentials: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        guard Self.isUsable(username), Self.isUsable(password) else {
            throw ProxyCredentialError.unusableValue
        }
        self.username = username
        self.password = password
    }

    /// 128 bits of username and 256 bits of password from the system CSPRNG,
    /// hex encoded so the values are safe in a YAML scalar.
    public static func random() throws -> Self {
        try Self(username: randomHex(bytes: 16), password: randomHex(bytes: 32))
    }

    public var description: String { "ProxyCredentials(redacted)" }
    public var debugDescription: String { description }

    private static func randomHex(bytes count: Int) throws -> String {
        var buffer = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &buffer) == errSecSuccess else {
            throw ProxyCredentialError.entropyUnavailable
        }
        return buffer.map { String(format: "%02x", $0) }.joined()
    }

    /// SOCKS5 username/password auth carries each field as a single length
    /// byte, so 1...255 bytes. Control characters would corrupt the generated
    /// configuration, so they are rejected rather than escaped.
    private static func isUsable(_ value: String) -> Bool {
        guard (1 ... 255).contains(value.utf8.count) else { return false }
        return !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

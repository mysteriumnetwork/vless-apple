/// Messages the app sends the packet tunnel extension.
///
/// The plugin keeps its own copy of `stats` rather than importing this
/// module — see `vlessStatsProviderMessage` in VPNUtils.swift. Change one
/// and you must change the other; they are a wire contract between two
/// processes.
public enum TunnelProviderMessages {
    /// Asks the provider for its byte counters.
    public static let stats = "VLESS_STATS"
}

/// Convenience alias used by the plugin and the provider.
public let vlessStatsProviderMessage = TunnelProviderMessages.stats

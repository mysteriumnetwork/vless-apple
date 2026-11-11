import Foundation

/// Coordinates the tun2socks worker, which runs a blocking call on its own
/// thread.
///
/// Two moments need care. `startTunnel` must not report success if the worker
/// returns immediately — that looks like a healthy tunnel that drops every
/// packet. And `stopTunnel` must tell an expected shutdown from a crash, so a
/// crash can be logged while a normal stop stays quiet.
///
/// All state is guarded by one condition, which also wakes the waiters.
public final class TunnelWorkerLifecycle: @unchecked Sendable {

    /// Outcome of waiting out the startup grace period.
    public enum Startup: Equatable {
        /// Still inside its run loop when the grace period elapsed.
        case running
        /// Returned before the grace period elapsed.
        case exited(code: Int32)
        /// The thread never reached its run loop.
        case neverStarted
    }

    private let condition = NSCondition()
    private var reachedRunLoop = false
    private var exitCode: Int32?
    private var stopRequested = false

    public init() {}

    /// Resets the state. Call immediately before spawning the worker thread.
    public func beginStart() {
        mutate {
            reachedRunLoop = false
            exitCode = nil
            stopRequested = false
        }
    }

    /// Call from the worker thread once it is about to block.
    public func markThreadEntered() {
        mutate { reachedRunLoop = true }
    }

    /// Call from the worker thread when its blocking call returns.
    ///
    /// Returns whether the exit was unexpected, i.e. nothing had asked it to
    /// stop — which means the worker died on its own.
    @discardableResult
    public func markExited(code: Int32) -> Bool {
        var unexpected = false
        mutate {
            exitCode = code
            unexpected = !stopRequested
        }
        return unexpected
    }

    /// Marks the worker as no longer wanted.
    ///
    /// Returns whether this call was the one that changed the flag, so only the
    /// first caller performs the shutdown.
    @discardableResult
    public func requestStop() -> Bool {
        var first = false
        mutate {
            first = !stopRequested && exitCode == nil
            stopRequested = true
        }
        return first
    }

    /// Blocks up to `gracePeriod` to see whether the worker stays up.
    public func waitForStableStartup(gracePeriod: TimeInterval) -> Startup {
        waitUntilExit(deadline: Date().addingTimeInterval(gracePeriod))

        condition.lock()
        defer { condition.unlock() }
        if let exitCode {
            return .exited(code: exitCode)
        }
        return reachedRunLoop ? .running : .neverStarted
    }

    /// Blocks up to `timeout` for the worker to return. Pass `0` for a
    /// non-blocking check. Returns whether it has exited.
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Bool {
        waitUntilExit(deadline: Date().addingTimeInterval(timeout))

        condition.lock()
        defer { condition.unlock() }
        return exitCode != nil
    }

    /// True once the worker is inside its run loop and has not returned.
    public var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return reachedRunLoop && exitCode == nil
    }

    /// True once a stop has been asked for.
    public var isStopRequested: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopRequested
    }

    // MARK: - Private

    private func mutate(_ body: () -> Void) {
        condition.lock()
        body()
        condition.broadcast()
        condition.unlock()
    }

    /// Sleeps until the worker exits or `deadline` passes, whichever is first.
    private func waitUntilExit(deadline: Date) {
        condition.lock()
        defer { condition.unlock() }
        while exitCode == nil, Date() < deadline {
            condition.wait(until: deadline)
        }
    }
}

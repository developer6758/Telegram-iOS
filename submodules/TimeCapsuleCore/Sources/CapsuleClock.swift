import Foundation
import Darwin

public enum CapsuleCountdown {
    public static func label(remainingSeconds: Int64) -> String {
        let total = max(0, min(31_536_000, remainingSeconds))
        guard total > 0 else { return "Tap to open" }
        let days = total / 86400
        let time = String(format: "%02lld:%02lld:%02lld", (total % 86400) / 3600, (total % 3600) / 60, total % 60)
        return days == 0 ? time : "\(days)d \(time)"
    }
    public static func remainingSeconds(unlockMs: Int64, estimatedServerMs: Int64) -> Int64 {
        guard unlockMs > estimatedServerMs else { return 0 }
        let delta = unlockMs.subtractingReportingOverflow(estimatedServerMs)
        guard !delta.overflow else { return 31_536_000 }
        return min(31_536_000, delta.partialValue / 1000 + (delta.partialValue % 1000 == 0 ? 0 : 1))
    }
}

/// Display only. A sample is never used to authorize key release. Anchors are deliberately
/// process-local, so an offline restart uses an unverified wall-clock estimate until resync.
public final class CapsuleClock {
    private let lock = NSLock()
    private var sample: (serverMs: Int64, continuousMs: Double, uncertaintyMs: Double)?
    public init() {}
    static func continuousMs() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000
    }
    public var hasVerifiedSample: Bool { lock.lock(); defer { lock.unlock() }; return sample != nil }
    public var uncertaintyMilliseconds: Double? { lock.lock(); defer { lock.unlock() }; return sample?.uncertaintyMs }
    func update(serverMs: Int64, startedAt: Double, receivedAt: Double) {
        guard serverMs > 0, receivedAt >= startedAt, receivedAt - startedAt <= 60_000 else { return }
        lock.lock(); defer { lock.unlock() }
        sample = (serverMs, receivedAt, (receivedAt - startedAt) / 2)
    }
    public var estimatedServerMs: Int64 {
        lock.lock(); let current = sample; lock.unlock()
        if let current = current {
            let elapsed = max(0, CapsuleClock.continuousMs() - current.continuousMs)
            return current.serverMs + Int64(min(elapsed, Double(Int64.max - current.serverMs)))
        }
        return Int64(Date().timeIntervalSince1970 * 1000)
    }
}

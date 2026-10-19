import Foundation

/// Monotonic deadline shared by the native input sampler and deterministic regression tests.
struct MenuIdleCountdown {
    let timeout: TimeInterval
    private(set) var lastActivity: TimeInterval
    init(now: TimeInterval, timeout: TimeInterval = 15) {
        self.timeout = timeout
        lastActivity = now
    }
    mutating func noteActivity(at timestamp: TimeInterval) {
        lastActivity = max(lastActivity, timestamp)
    }
    func isExpired(at now: TimeInterval) -> Bool { now - lastActivity >= timeout }
}

struct MenuActivityPolicy {
    static func relevantTimestamp(mouse: TimeInterval?, keyboard: TimeInterval?, any: TimeInterval?,
                                  pointerInMenu: Bool, pointerWasInMenu: Bool,
                                  hasOpenMenu: Bool, settingsActive: Bool) -> TimeInterval? {
        var candidates: [TimeInterval] = []
        if let mouse, pointerInMenu || pointerWasInMenu { candidates.append(mouse) }
        if let keyboard, hasOpenMenu || settingsActive { candidates.append(keyboard) }
        if let any, settingsActive { candidates.append(any) }
        return candidates.max()
    }
}

import Foundation

/// Neutral releases must survive BLE backpressure independently of the latest input slot.
struct HIDSessionReleaseQueue {
    private var frames: [(id: UInt8, data: Data)] = []
    var next: (id: UInt8, data: Data)? { frames.first }
    mutating func replace(_ frames: [(id: UInt8, data: Data)]) { self.frames = frames }
    mutating func accepted() { if !frames.isEmpty { frames.removeFirst() } }
    mutating func clear() { frames.removeAll() }
}

/// SPEC §7.3 C — which device input is currently routed to.
///
/// `pc` is the existing Bluetooth HID-over-GATT path to Windows (unchanged); `tv` is the
/// separate local-network target. TV is a target, not a fourth PC mode, so `RemoteTarget`
/// stays orthogonal to `PadMode` and `GameInputMode`.
enum RemoteTarget: String, Sendable {
    case pc
    case tv
}

/// SPEC §7.3 C — the root-owned gate that binds queued work and captured callbacks to the
/// target/session that created them.
///
/// Queued work (the typing queue, arrow repeaters, GameController handlers) and captured
/// closures hold a session `token`; `transition(to:)`, `suspend()` and `resume()` each move
/// the generation forward, so a token from an older session never satisfies `accepts(_:)`
/// again. Stale work is then discarded instead of replaying old presses, text or repeats, and
/// the next session always starts neutral.
///
/// Foundation-only, no Combine: the state is plain mutable state mutated only on the main
/// actor. The root owns exactly one instance and creates the gated PC `HIDInput` closure
/// bundle with a token captured per root PC view; the TV view stays totally separate.
@MainActor
final class RemoteTargetSession {
    /// One live session identity: the bound target plus a monotonically changing generation.
    /// Sendable and Equatable so a queued task or captured closure can hold it and compare
    /// it cheaply before sending anything.
    struct Token: Sendable, Equatable {
        let target: RemoteTarget
        let generation: UInt64
    }

    private(set) var target: RemoteTarget
    private(set) var generation: UInt64 = 0
    /// SPEC §7.3 D: control is a foreground action — a backgrounded app holds no live session.
    private(set) var isActive = true

    init(target: RemoteTarget = .pc) {
        self.target = target
    }

    /// The current session token; capture it when creating a closure or queueing work.
    var token: Token {
        Token(target: target, generation: generation)
    }

    /// True only for a live (active) session whose target + generation still match.
    /// A holder that gets `false` must drop its queued work and captured closures
    /// without sending anything.
    func accepts(_ token: Token) -> Bool {
        isActive && token == Token(target: target, generation: generation)
    }

    /// SPEC §7.3 C: change target before the next session begins; every token issued for the
    /// old target (and every closure/queue bound to it) is invalidated immediately.
    func transition(to newTarget: RemoteTarget) {
        target = newTarget
        generation &+= 1
    }

    /// SPEC §7.3 C: the app is leaving the foreground; invalidate work queued before the
    /// suspension so nothing held or queued can fire on return ("reactivation must not
    /// resume a held/repeating key").
    func suspend() {
        isActive = false
        generation &+= 1
    }

    /// SPEC §7.3 C: the app is back; a fresh session begins and must never replay the
    /// previous session's presses, text or repeats.
    func resume() {
        isActive = true
        generation &+= 1
    }
}

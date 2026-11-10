// P3.174AX: first-party typed observation source, built against upstream
// swift-6.0-RELEASE official Observation sources by isolated macOS CI.
// This is NOT an Apple 17/18 runtime claim, metadata alias or shim provider.
// All exported probes are source-owned Swift generic KeyPath+ARC calls.
import Observation

final class P3174AXObserved: Observable {
    let registrar = ObservationRegistrar()
    private var storage = 0

    var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return storage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) {
                storage = newValue
            }
        }
    }

    func setByExplicitPair(_ next: Int) {
        registrar.willSet(self, keyPath: \.value)
        storage = next
        registrar.didSet(self, keyPath: \.value)
    }
}

@_cdecl("p3174ax_observation_one_shot_typed")
public func p3174axOneShotTyped() -> Int32 {
    let watched = P3174AXObserved()
    let unrelated = P3174AXObserved()
    var notices = 0

    let first = withObservationTracking({
        watched.value
    }, onChange: {
        notices += 1
    })
    if first != 0 || notices != 0 { return -11 }

    // Other object has same Observable type and KeyPath, yet must not
    // invalidate the tracked instance.
    unrelated.value = 8
    if unrelated.value != 8 || notices != 0 { return -12 }

    watched.value = 1
    if watched.value != 1 || notices != 1 { return -13 }

    // ObservationTracking is one-shot: without registration anew,
    // another mutation must not spuriously deliver a second callback.
    watched.value = 2
    if watched.value != 2 || notices != 1 { return -14 }

    var second = 0
    let snapshot = withObservationTracking({
        watched.value
    }, onChange: {
        second += 1
    })
    if snapshot != 2 || second != 0 { return -15 }
    watched.value = 3
    if watched.value != 3 || second != 1 || notices != 1 { return -16 }

    return 1
}

@_cdecl("p3174ax_observation_will_did_typed")
public func p3174axWillDidTyped() -> Int32 {
    let tracked = P3174AXObserved()
    var notices = 0

    let initial = withObservationTracking({
        tracked.value
    }, onChange: {
        notices += 1
    })
    if initial != 0 || notices != 0 { return -21 }

    tracked.setByExplicitPair(10)
    if notices != 1 || tracked.value != 10 { return -22 }

    // Explicit setter pair should not notify a disposed one-shot watcher.
    tracked.setByExplicitPair(11)
    if notices != 1 || tracked.value != 11 { return -23 }

    var next = 0
    let previous = withObservationTracking({
        tracked.value
    }, onChange: {
        next += 1
    })
    if previous != 11 { return -24 }
    tracked.setByExplicitPair(12)
    if tracked.value != 12 || next != 1 { return -25 }

    return 1
}

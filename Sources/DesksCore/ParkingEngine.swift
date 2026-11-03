import AppKit
import ApplicationServices

/// What we last told a window to do.
enum Placement: Equatable {
    case visible
    case parked(CGPoint)
}

/// The wanted state of one live window, computed by the engine from the model.
struct Desire {
    let window: LiveWindow
    let visible: Bool
    /// Frame to restore when it is shown.
    let home: CGRect
    /// Top-left point to park it at when it is hidden.
    let parkPoint: CGPoint
    /// The window sits in a corner now (for example after a crash), whatever we think.
    let looksParked: Bool
    /// Move it to `home` even if we think it is already visible (display reconnect, rescue).
    let forceHome: Bool
}

/// Turns wanted states into AX moves.
/// Moves only by position when parking (no size change), so about 1 px stays on screen.
/// Shows the target windows first, then parks the others, to reduce flicker.
/// Main thread, except the jobs it sends to each app's queue.
final class ParkingEngine {
    private let tracker: WindowTracker
    private(set) var applied: [CGWindowID: Placement] = [:]
    private var movedAt: [CGWindowID: Date] = [:]
    /// How often a window jumped back on screen after we parked it at its current target.
    private var jumpBacks: [CGWindowID: Int] = [:]
    /// Windows to park again at the same point (they jumped back).
    private var needsRepark: Set<CGWindowID> = []

    /// Frame a window had just before we parked it. Only for windows that were visible.
    var onParked: ((CGWindowID, CGRect) -> Void)?

    init(tracker: WindowTracker) { self.tracker = tracker }

    func isParked(_ id: CGWindowID) -> Bool {
        if case .parked = applied[id] { return true }
        return false
    }

    /// True for about a second after we moved the window. Its frame events are then ours, not the user's.
    func isInTransit(_ id: CGWindowID) -> Bool {
        guard let date = movedAt[id] else { return false }
        return Date().timeIntervalSince(date) < 1.0
    }

    func forget(_ id: CGWindowID) {
        applied[id] = nil
        movedAt[id] = nil
        jumpBacks[id] = nil
        needsRepark.remove(id)
    }

    func forgetAll() {
        applied = [:]
        movedAt = [:]
        jumpBacks = [:]
        needsRepark = []
    }

    /// The window came back on screen by itself (some apps do). Lets the next sync park it again,
    /// at most 3 times per park target. Returns false when the limit is reached.
    @discardableResult
    func requestRepark(_ id: CGWindowID) -> Bool {
        guard jumpBacks[id, default: 0] < 3 else { return false }
        jumpBacks[id, default: 0] += 1
        needsRepark.insert(id)
        return true
    }

    /// Applies the wanted states. `beforePark` runs after `applied` is updated and before any park is sent:
    /// the engine writes the crash journal there. `completion` runs on main after the show phase.
    func sync(_ desires: [Desire], beforePark: () -> Void, completion: (() -> Void)? = nil) {
        var shows: [(LiveWindow, CGRect)] = []
        var parks: [(LiveWindow, CGPoint, Bool)] = []
        for desire in desires {
            let id = desire.window.windowId
            let current = applied[id]
            if desire.visible {
                var needsMove = desire.forceHome
                switch current {
                case .parked: needsMove = true
                case nil: needsMove = needsMove || desire.looksParked
                case .visible: break
                }
                if current != .visible {
                    jumpBacks[id] = nil
                    needsRepark.remove(id)
                }
                applied[id] = .visible
                if needsMove { shows.append((desire.window, desire.home)) }
            } else {
                let target = Placement.parked(desire.parkPoint)
                if current == target, !needsRepark.contains(id) { continue }
                if current != target { jumpBacks[id] = nil }
                needsRepark.remove(id)
                let fromVisible = current == .visible || (current == nil && !desire.looksParked)
                applied[id] = target
                parks.append((desire.window, desire.parkPoint, fromVisible))
            }
        }

        let group = DispatchGroup()
        for (window, home) in shows {
            guard let watcher = tracker.watcher(window.pid) else { continue }
            movedAt[window.windowId] = Date()
            group.enter()
            watcher.queue.async {
                // A failed show is caught by the engine on the next snapshot (visible but in a corner).
                _ = Self.show(window.windowId, at: home, watcher: watcher)
                group.leave()
            }
        }

        if !parks.isEmpty { beforePark() }

        var done = false
        let parkPhase = { [weak self] in
            guard let self, !done else { return }
            done = true
            for (window, point, fromVisible) in parks {
                // A newer sync may have changed its mind about this window.
                guard self.applied[window.windowId] == .parked(point) else { continue }
                self.sendPark(window, to: point, fromVisible: fromVisible)
            }
            completion?()
        }
        if shows.isEmpty {
            parkPhase()
        } else {
            group.notify(queue: .main, execute: parkPhase)
            // A slow app must not hold back the rest.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: parkPhase)
        }
    }

    private func sendPark(_ window: LiveWindow, to point: CGPoint, fromVisible: Bool) {
        guard let watcher = tracker.watcher(window.pid) else { return }
        let id = window.windowId
        movedAt[id] = Date()
        watcher.queue.async { [weak self] in
            guard let element = watcher.element(for: id) else { return }
            let before = AX.frame(element)
            AX.withEnhancedUIOff(watcher.app) { _ = AX.setPosition(element, point) }
            // Verify and retry once: some apps clamp or jump back.
            if let after = AX.position(element), abs(after.x - point.x) > 2 || abs(after.y - point.y) > 2 {
                usleep(30_000)
                AX.withEnhancedUIOff(watcher.app) { _ = AX.setPosition(element, point) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.movedAt[id] = Date()
                if fromVisible, let before { self.onParked?(id, before) }
            }
        }
    }

    /// Moves one window to `frame`, checks where it landed and retries once.
    /// Returns true when the final position is right. Call on the app's queue.
    @discardableResult
    static func show(_ id: CGWindowID, at frame: CGRect, watcher: AppWatcher) -> Bool {
        guard let element = watcher.element(for: id) else { return false }
        move(element, to: frame, app: watcher.app)
        if landed(element, at: frame.origin) { return true }
        usleep(50_000)
        move(element, to: frame, app: watcher.app)
        return landed(element, at: frame.origin)
    }

    private static func landed(_ element: AXUIElement, at point: CGPoint) -> Bool {
        guard let now = AX.position(element) else { return false }
        return abs(now.x - point.x) <= 2 && abs(now.y - point.y) <= 2
    }

    private static func move(_ element: AXUIElement, to frame: CGRect, app: AXUIElement) {
        AX.withEnhancedUIOff(app) {
            let size = AX.size(element)
            let sizeDiffers = size.map { abs($0.width - frame.width) > 1 || abs($0.height - frame.height) > 1 } ?? false
            if sizeDiffers, frame.width > 0, frame.height > 0 {
                // Size, position, size: the order AeroSpace found to work best.
                AX.setSize(element, frame.size)
                AX.setPosition(element, frame.origin)
                AX.setSize(element, frame.size)
            } else {
                AX.setPosition(element, frame.origin)
            }
        }
    }

    /// Stops managing one window. If we parked it, it is shown at `home` first (verified, one retry).
    /// `done` runs on main with true when the window is on screen (or was never parked). Does not wait.
    func release(_ id: CGWindowID, pid: pid_t, home: CGRect, done: @escaping (Bool) -> Void) {
        let wasParked = isParked(id)
        forget(id)
        guard wasParked else { done(true); return }
        guard let watcher = tracker.watcher(pid) else { done(false); return }
        watcher.queue.async {
            let ok = Self.show(id, at: home, watcher: watcher)
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Shows the given windows at their frames and blocks up to `timeout` seconds.
    /// Returns the ids whose final position was verified. Used on pause and quit.
    func showAll(_ targets: [(pid: pid_t, windowId: CGWindowID, frame: CGRect)], timeout: Double = 3.0) -> Set<CGWindowID> {
        let group = DispatchGroup()
        let lock = NSLock()
        var verified = Set<CGWindowID>()
        for target in targets {
            applied[target.windowId] = .visible
            guard let watcher = tracker.watcher(target.pid) else { continue }
            movedAt[target.windowId] = Date()
            group.enter()
            watcher.queue.async {
                if Self.show(target.windowId, at: target.frame, watcher: watcher) {
                    lock.lock(); verified.insert(target.windowId); lock.unlock()
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return verified
    }
}

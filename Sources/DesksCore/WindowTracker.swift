import AppKit
import ApplicationServices

/// One window as read from AX. Frame in AX coordinates.
struct LiveWindow: Equatable {
    let windowId: CGWindowID
    let pid: pid_t
    let bundleId: String
    let role: String
    let subrole: String
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let isFullScreen: Bool
    /// Order among the app's standard windows (-1 for other windows).
    let index: Int

    var isStandard: Bool { role == kAXWindowRole && subrole == kAXStandardWindowSubrole }

    /// Dialogs and panels that follow the layout of their app's last focused window.
    var isFollower: Bool {
        role == kAXWindowRole && !isMinimized
            && (subrole == kAXDialogSubrole || subrole == kAXFloatingWindowSubrole || subrole == kAXSystemDialogSubrole)
    }
}

/// Everything we read from one app in one pass.
struct AppSnapshot {
    let pid: pid_t
    let bundleId: String
    let windows: [LiveWindow]
    let focusedWindowId: CGWindowID?
    /// False when the app did not answer. Then missing windows must not be treated as closed.
    let complete: Bool
}

private let appNotifications = [
    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
]
private let windowNotifications = [
    kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
]

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    // The source runs on the main run loop, so this is the main thread.
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.received(notification as String, element: element)
}

/// Watches one app. AX calls run on its own serial queue; the observer source runs on the main run loop.
final class AppWatcher {
    let pid: pid_t
    let bundleId: String
    let queue: DispatchQueue
    let app: AXUIElement
    weak var tracker: WindowTracker?

    // Main thread only.
    private var source: CFRunLoopSource?
    private var stopped = false
    private(set) var isObserving = false
    private(set) var failed = false

    // Queue only.
    private var observer: AXObserver?
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var observed: Set<CGWindowID> = []
    /// The element each window notification was added on. A destroyed element can not tell its id,
    /// so the id is found here with CFEqual.
    private var observedElements: [CGWindowID: AXUIElement] = [:]
    /// Elements dropped by a snapshot, kept a few seconds: the destroyed event can come after the snapshot.
    private var recentlyGone: [(id: CGWindowID, element: AXUIElement, at: Date)] = []

    init(pid: pid_t, bundleId: String) {
        self.pid = pid
        self.bundleId = bundleId
        queue = DispatchQueue(label: "desks.ax.\(pid)", qos: .userInitiated)
        app = AXUIElementCreateApplication(pid)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func start() {
        queue.async { [self] in
            AX.setTimeout(app)
            var created: AXObserver?
            guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let created else {
                DispatchQueue.main.async { self.failed = true }
                return
            }
            var ok = false
            for name in appNotifications {
                if AXObserverAddNotification(created, app, name as CFString, refcon) == .success { ok = true }
            }
            guard ok else {
                DispatchQueue.main.async { self.failed = true }
                return
            }
            observer = created
            let runLoopSource = AXObserverGetRunLoopSource(created)
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                self.source = runLoopSource
                self.isObserving = true
                self.tracker?.refresh(self.pid, after: 0)
            }
        }
    }

    /// Call on the main thread. Jobs already queued still run.
    func stop() {
        stopped = true
        isObserving = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        queue.async { [self] in
            if let observer {
                for name in appNotifications { AXObserverRemoveNotification(observer, app, name as CFString) }
                for element in observedElements.values {
                    for name in windowNotifications { AXObserverRemoveNotification(observer, element, name as CFString) }
                }
            }
            observer = nil
            elements = [:]
            observed = []
            observedElements = [:]
            recentlyGone = []
        }
    }

    /// Main thread, from the AX callback.
    func received(_ notification: String, element: AXUIElement) {
        guard !stopped else { return }
        guard notification == kAXUIElementDestroyedNotification else {
            tracker?.event(notification, pid: pid, windowId: nil)
            return
        }
        // Find which window was destroyed. Popups and tooltips send this too; the engine decides.
        queue.async { [self] in
            let id = destroyedWindowId(element)
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                self.tracker?.event(notification, pid: self.pid, windowId: id)
            }
        }
    }

    // MARK: Queue-only work

    /// The id of a window element we observed, matched with CFEqual. Call on `queue`.
    private func destroyedWindowId(_ element: AXUIElement) -> CGWindowID? {
        if let (id, _) = observedElements.first(where: { CFEqual($0.value, element) }) {
            observedElements[id] = nil
            observed.remove(id)
            return id
        }
        return recentlyGone.first { CFEqual($0.element, element) }?.id
    }

    /// Reads all windows of the app. Call on `queue`.
    func readSnapshot() -> AppSnapshot {
        guard let list = AX.elements(app, kAXWindowsAttribute) else {
            return AppSnapshot(pid: pid, bundleId: bundleId, windows: [], focusedWindowId: nil, complete: false)
        }
        var windows: [LiveWindow] = []
        var fresh: [CGWindowID: AXUIElement] = [:]
        var standardIndex = 0
        for element in list {
            guard let id = AX.windowId(element) else { continue }
            if elements[id] == nil { AX.setTimeout(element) }
            fresh[id] = element
            guard let frame = AX.frame(element) else { continue }
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            let subrole = AX.string(element, kAXSubroleAttribute) ?? ""
            let isStandard = role == kAXWindowRole && subrole == kAXStandardWindowSubrole
            windows.append(LiveWindow(
                windowId: id, pid: pid, bundleId: bundleId, role: role, subrole: subrole,
                title: AX.string(element, kAXTitleAttribute) ?? "",
                frame: frame,
                isMinimized: AX.bool(element, kAXMinimizedAttribute) ?? false,
                isFullScreen: AX.bool(element, AX.fullScreen) ?? false,
                index: isStandard ? standardIndex : -1))
            if isStandard { standardIndex += 1 }
            if let observer, !observed.contains(id) {
                for name in windowNotifications { AXObserverAddNotification(observer, element, name as CFString, refcon) }
                observed.insert(id)
                observedElements[id] = element
            }
        }
        elements = fresh
        observed.formIntersection(fresh.keys)
        let now = Date()
        recentlyGone.removeAll { now.timeIntervalSince($0.at) > 5 }
        for (id, element) in observedElements where fresh[id] == nil {
            recentlyGone.append((id, element, now))
            observedElements[id] = nil
        }
        let focused = AX.element(app, kAXFocusedWindowAttribute).flatMap(AX.windowId)
        return AppSnapshot(pid: pid, bundleId: bundleId, windows: windows, focusedWindowId: focused, complete: true)
    }

    /// The AX element of a window. Call on `queue`.
    func element(for id: CGWindowID) -> AXUIElement? {
        if let element = elements[id] { return element }
        guard let list = AX.elements(app, kAXWindowsAttribute) else { return nil }
        for element in list where AX.windowId(element) == id {
            AX.setTimeout(element)
            elements[id] = element
            return element
        }
        return nil
    }

    /// All window elements with their ids, read fresh. Call on `queue`.
    func allElements() -> [(CGWindowID, AXUIElement)] {
        guard let list = AX.elements(app, kAXWindowsAttribute) else { return [] }
        return list.compactMap { element in AX.windowId(element).map { ($0, element) } }
    }
}

/// Keeps one AppWatcher per regular app and turns AX and NSWorkspace events into snapshots.
/// Lives on the main thread.
final class WindowTracker {
    private(set) var watchers: [pid_t: AppWatcher] = [:]
    private var retries: [pid_t: Int] = [:]
    private var pending: [pid_t: (deadline: DispatchTime, item: DispatchWorkItem)] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var running = false

    var onSnapshot: ((AppSnapshot) -> Void)?
    /// Raw AX notification name for an app (for close and focus handling). For a destroyed event,
    /// the window id when the element was one of the app's windows we observed, else nil.
    var onEvent: ((String, pid_t, CGWindowID?) -> Void)?
    var onAppActivated: ((pid_t) -> Void)?
    var onAppGone: ((pid_t) -> Void)?
    var onAppHidden: ((pid_t) -> Void)?

    func start() {
        guard !running else { return }
        running = true
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ handler: @escaping (pid_t?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                handler(app?.processIdentifier)
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] _ in
            self?.scanApps()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.scanApps() }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
            guard let self, let pid else { return }
            self.removeWatcher(pid)
            self.onAppGone?(pid)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
            guard let self, let pid else { return }
            if self.watchers[pid] == nil { self.scanApps() }
            self.refresh(pid, after: 0)
            self.onAppActivated?(pid)
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] pid in
            guard let self, let pid else { return }
            self.onAppHidden?(pid)
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] pid in
            guard let pid else { return }
            self?.refresh(pid, after: 0.1)
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.refreshAll(after: 0.3)
        }
        scanApps()
        let timer = Timer(timeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.scanApps()
            self?.refreshAll(after: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        guard running else { return }
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        pollTimer?.invalidate()
        pollTimer = nil
        pending.values.forEach { $0.item.cancel() }
        pending = [:]
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        retries = [:]
    }

    /// Adds watchers for new regular apps, retries failed ones, drops dead ones.
    func scanApps() {
        guard running else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        var alive = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != me, pid > 0, !app.isTerminated else { continue }
            alive.insert(pid)
            if let existing = watchers[pid] {
                guard existing.failed, retries[pid, default: 0] < 15 else { continue }
                existing.stop()
                retries[pid, default: 0] += 1
            }
            let watcher = AppWatcher(pid: pid, bundleId: app.bundleIdentifier ?? "pid.\(pid)")
            watcher.tracker = self
            watchers[pid] = watcher
            watcher.start()
        }
        for pid in watchers.keys where !alive.contains(pid) {
            removeWatcher(pid)
            onAppGone?(pid)
        }
    }

    private func removeWatcher(_ pid: pid_t) {
        watchers.removeValue(forKey: pid)?.stop()
        pending.removeValue(forKey: pid)?.item.cancel()
        retries[pid] = nil
    }

    func watcher(_ pid: pid_t) -> AppWatcher? { watchers[pid] }

    /// Runs a job on the app's AX queue.
    func perform(_ pid: pid_t, _ job: @escaping (AppWatcher) -> Void) {
        guard let watcher = watchers[pid] else { return }
        watcher.queue.async { job(watcher) }
    }

    /// Reads the app again after `delay`. Requests close together are merged.
    func refresh(_ pid: pid_t, after delay: Double) {
        guard running, let watcher = watchers[pid] else { return }
        let deadline = DispatchTime.now() + delay
        if let existing = pending[pid], existing.deadline <= deadline { return }
        pending[pid]?.item.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending[pid] = nil
            watcher.queue.async {
                let snapshot = watcher.readSnapshot()
                DispatchQueue.main.async {
                    guard self.running, self.watchers[pid] === watcher else { return }
                    self.onSnapshot?(snapshot)
                }
            }
        }
        pending[pid] = (deadline, item)
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: item)
    }

    func refreshAll(after delay: Double) {
        for pid in watchers.keys { refresh(pid, after: delay) }
    }

    /// Main thread, from AppWatcher.
    func event(_ name: String, pid: pid_t, windowId: CGWindowID?) {
        onEvent?(name, pid, windowId)
        switch name {
        case kAXWindowCreatedNotification, kAXUIElementDestroyedNotification:
            // Destroyed is not reliable and new windows fill in late, so read again a few times.
            refresh(pid, after: 0.05)
            for delay in [0.5, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh(pid, after: 0) }
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            refresh(pid, after: 0)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            refresh(pid, after: 0.25)
        default:
            refresh(pid, after: 0.05)
        }
    }

    /// Window ids that exist anywhere (any Space), by pid. Public CG call, no permission needed for ids.
    static func existingWindowIds(for pid: pid_t) -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result = Set<CGWindowID>()
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            result.insert(CGWindowID(number.uint32Value))
        }
        return result
    }
}

import AppKit
import ApplicationServices

/// The real engine. Everything here runs on the main thread; AX work goes to each app's queue.
final class LiveEngine: DesksEngine {
    // MARK: Contract state

    private(set) var status: DesksStatus = .needsAccessibility
    private(set) var warnings: [String] = []
    var onChange: (() -> Void)?
    var options = EngineOptions() {
        didSet {
            guard options != oldValue else { return }
            refreshScreens()
            syncPlacements()
            notify()
        }
    }

    var displays: [DisplayState] { buildDisplays() }

    // MARK: Parts

    private let store = Store()
    private let model = LayoutModel()
    private let tracker: WindowTracker
    private let parking: ParkingEngine

    // MARK: Runtime state

    private var screens: [ScreenInfo] = []
    private var corners: [DisplayID: HideCorner] = [:]
    private var blockedScreens: [ScreenInfo] = []
    /// Live data of managed windows by window id.
    private var live: [CGWindowID: LiveWindow] = [:]
    /// Dialogs and panels: not members, they follow their app's last focused member.
    private var followers: [CGWindowID: LiveWindow] = [:]
    private var followerHome: [CGWindowID: CGRect] = [:]
    /// Saved windows not matched yet, with the time they expire.
    private var pendingSaved: [(record: WindowRecord, until: Date)] = []
    private var pendingStartsOnBegin = true
    private var lastMemberByPid: [pid_t: String] = [:]
    private var focusedByPid: [pid_t: CGWindowID] = [:]
    private var lastFocusedDisplay: String?
    private var forceHome: Set<CGWindowID> = []
    /// How often we re-showed a window that stayed in a corner after a show. Bounded.
    private var showRetry: [CGWindowID: Int] = [:]
    /// Apps that got a didActivateApplication; their next snapshot checks focus even if the id did not change.
    private var activatedPids: Set<pid_t> = []
    /// Last close, minimize, hide or quit per app.
    private var lastCloseAt: [pid_t: Date] = [:]
    /// Journal entries from an earlier run that could not be restored yet. Kept in the journal.
    private var legacyJournal: [JournalEntry] = []

    // v1.1: rules, apps to open, arrangements.
    private var compiledPatterns: [UUID: NSRegularExpression] = [:]
    private var invalidRules: [WindowRule] = []
    /// Windows an "ignore" rule keeps out of Desks, with their last live data.
    private var ignored: [CGWindowID: LiveWindow] = [:]
    /// New windows waiting for a title, because a title rule exists for their app.
    private var firstSeen: [CGWindowID: Date] = [:]
    /// Apps launched for a layout: their first new window joins that layout.
    private var pendingTargets: [String: (display: String, layout: Int, until: Date)] = [:]
    /// New windows a rule or a launch put into a hidden layout. Focus on them does not switch layouts.
    private var autoPlacedAt: [CGWindowID: Date] = [:]
    /// Per display: a missing layout id that was asked for, and the layout created at the end for it.
    /// Later requests for the same missing id reuse that layout instead of adding another.
    private var createdFor: [String: [Int: Int]] = [:]
    /// Last time each window (by key) had focus.
    private var lastFocusedAt: [String: Date] = [:]
    /// Windows let back in after their ignore rule went away: they join the current layout, no rules.
    private var releasedFromIgnore: Set<CGWindowID> = []
    /// Focus into a parked window does not switch layouts before this time (after a close or our own switch).
    private var suppressFocusSwitchUntil = Date.distantPast
    /// Frame and display updates are ignored before this time (display change, wake).
    private var settleUntil = Date.distantPast

    private var started = false
    private var active = false
    private var isShutDown = false
    private var promptedThisLaunch = false
    private var timer: Timer?
    private var timerTicks = 0
    private var systemTokens: [NSObjectProtocol] = []
    private var notifyScheduled = false
    private var screenChangeItem: DispatchWorkItem?
    /// A frame changed without a membership change: save, but do not notify the UI.
    private var framesDirty = false

    init() {
        let tracker = WindowTracker()
        self.tracker = tracker
        parking = ParkingEngine(tracker: tracker)
        tracker.onSnapshot = { [weak self] in self?.reconcile($0) }
        tracker.onEvent = { [weak self] name, pid in
            if name == kAXUIElementDestroyedNotification || name == kAXWindowMiniaturizedNotification {
                self?.noteClose(pid)
            }
        }
        tracker.onAppGone = { [weak self] in self?.appGone($0) }
        tracker.onAppHidden = { [weak self] in self?.noteClose($0) }
        tracker.onAppActivated = { [weak self] in self?.activatedPids.insert($0) }
        parking.onParked = { [weak self] id, frame in self?.parked(id, frameBefore: frame) }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let saved = model.load(store.loadState() ?? ModelState())
        pendingSaved = saved.map { ($0, Date.distantFuture) }
        compileRules()
        refreshScreens()
        observeSystem()

        let tick = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.onTimer() }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick

        if AX.isTrusted() {
            beginManaging()
        } else {
            status = .needsAccessibility
            if !promptedThisLaunch {
                promptedThisLaunch = true
                AX.promptForTrust()
            }
        }
        updateWarnings()
        notify()
    }

    func pause() {
        guard started, status == .running else { return }
        stopManaging(restore: true)
        status = .paused
        notify()
    }

    func resume() {
        guard started, !isShutDown, status == .paused else { return }
        if AX.isTrusted() {
            beginManaging()
        } else {
            status = .needsAccessibility
        }
        notify()
    }

    func shutdown() {
        guard started, !isShutDown else { return }
        isShutDown = true
        if active { stopManaging(restore: true) }
        timer?.invalidate()
        timer = nil
        store.saveNow(snapshotState())
    }

    private func beginManaging() {
        guard !active, !isShutDown else { return }
        active = true
        status = .running
        if pendingStartsOnBegin {
            pendingStartsOnBegin = false
            let until = Date().addingTimeInterval(600)
            pendingSaved = pendingSaved.map { ($0.record, until) }
        }
        refreshScreens()
        // The saved current layouts win over whatever window happens to be focused at launch.
        suppressFocusSwitchUntil = Date().addingTimeInterval(2.0)
        // Apps that quit while we were paused: keep their windows for matching, drop them from the model.
        let gone = Set(model.allRecords.map(\.pid)).filter { pid in
            NSRunningApplication(processIdentifier: pid).map { $0.isTerminated } ?? true
        }
        gone.forEach(appGone)
        tracker.start()
        rescueFromJournal()
        notify()
    }

    /// Stops tracking. With `restore`, brings every parked window back first and clears the journal.
    private func stopManaging(restore: Bool) {
        guard active else { return }
        if restore {
            // Keep in the journal every window whose move back was not verified, for the next launch.
            var entries = journalEntries()
            let ids = Set(entries.map(\.windowId))
            entries.append(contentsOf: legacyJournal.filter { !ids.contains($0.windowId) })
            let verified = parking.showAll(parkedTargets(), timeout: 2.5)
            legacyJournal = []
            store.writeJournal(entries.filter { !verified.contains($0.windowId) })
        }
        tracker.stop()
        active = false
        parking.forgetAll()
        live = [:]
        followers = [:]
        followerHome = [:]
        focusedByPid = [:]
        forceHome = []
        showRetry = [:]
        activatedPids = []
        store.saveNow(snapshotState())
    }

    private func onTimer() {
        timerTicks += 1
        let trusted = AX.isTrusted()
        if trusted, !active, status == .needsAccessibility, !isShutDown {
            beginManaging()
        } else if !trusted, active {
            // Permission was taken away. AX no longer works, so nothing can be moved back now.
            // The journal on disk is kept as it is: the next trusted start restores those windows.
            tracker.stop()
            active = false
            parking.forgetAll()
            live = [:]
            followers = [:]
            status = .needsAccessibility
            notify()
        }
        if timerTicks % 5 == 0 { updateWarnings() }
    }

    private func observeSystem() {
        let app = NotificationCenter.default
        systemTokens.append(app.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in self?.screensChanged() })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            systemTokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screensChanged()
            })
        }
        systemTokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.store.saveNow(self.snapshotState())
        })
        systemTokens.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.notify()
        })
    }

    // MARK: Contract actions

    func switchTo(layout id: Int, on display: DisplayID?) {
        guard status == .running, (0...LayoutModel.maxLayoutId).contains(id), let uuid = resolveDisplay(display) else { return }
        guard id != model.current(on: uuid) else { return }
        performSwitch(to: id, on: uuid, focusKey: nil, launchApps: true)
    }

    func switchRelative(_ delta: Int, on display: DisplayID?) {
        guard status == .running, delta != 0, let uuid = resolveDisplay(display) else { return }
        let ids = model.layoutIds(on: uuid)
        guard ids.count > 1, let index = ids.firstIndex(of: model.current(on: uuid)) else { return }
        let next = ids[((index + delta) % ids.count + ids.count) % ids.count]
        performSwitch(to: next, on: uuid, focusKey: nil, launchApps: true)
    }

    @discardableResult
    func createLayout(on display: DisplayID?) -> Int? {
        guard status == .running, let uuid = resolveDisplay(display), let id = model.appendLayout(on: uuid) else { return nil }
        performSwitch(to: id, on: uuid, focusKey: nil)
        // Switching away may have removed an empty layout below it, so read the id back.
        return model.current(on: uuid)
    }

    func deleteLayout(_ id: Int, on display: DisplayID) {
        guard id != 0, model.hasLayout(id, on: display.uuid) else { return }
        let wasCurrent = model.current(on: display.uuid) == id
        removeLayout(id, on: display.uuid)
        if wasCurrent {
            performSwitch(to: 0, on: display.uuid, focusKey: nil, force: true)
        } else {
            syncPlacements()
            changed()
        }
    }

    func renameLayout(_ id: Int, on display: DisplayID, to name: String) {
        model.renameLayout(id, on: display.uuid, to: name)
        changed()
    }

    func moveFocusedWindow(toLayout id: Int) {
        guard let token = focusedWindowToken() else { return }
        moveWindow(token, toLayout: id)
    }

    func toggleStickyFocusedWindow() {
        guard let token = focusedWindowToken() else { return }
        setSticky(token, !isSticky(token))
    }

    func focusedDisplay() -> DisplayID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowId = focusedByPid[pid] else { return nil }
        let connected = connectedSet
        if let record = model.record(forWindowId: windowId) {
            let display = model.placement(of: record, connected: connected, mainUUID: mainUUID).display
            if connected.contains(display) { return DisplayID(uuid: display) }
        }
        if let window = live[windowId] ?? followers[windowId] {
            return Screens.screen(for: window.frame, in: screens)?.id
        }
        return nil
    }

    func rescueAllWindows() {
        let connected = connectedSet
        let main = mainUUID
        for record in model.allRecords where !record.sticky {
            model.update(record.key) { r in
                if connected.contains(r.display) {
                    r.layout = model.current(on: r.display)
                } else if let main {
                    r.orphanLayout = model.current(on: main)
                }
            }
        }
        if active {
            for (id, window) in live where Screens.looksParked(window.frame, in: screens) { forceHome.insert(id) }
            syncPlacements()
        }
        rescueStrays()
        changed()
    }

    func focusedWindowToken() -> WindowToken? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowId = focusedByPid[pid],
              let key = model.key(forWindowId: windowId) else { return nil }
        return WindowToken(key: key)
    }

    func moveWindow(_ token: WindowToken, toLayout id: Int) {
        guard status == .running, (0...LayoutModel.maxLayoutId).contains(id), let record = model.record(token.key) else { return }
        let connected = connectedSet
        let wasFocused = focusedWindowToken() == token
        var uuid = record.display
        if !connected.contains(uuid), let main = mainUUID {
            // Orphan: it now belongs to the main display for good.
            uuid = main
            model.update(token.key) { r in
                r.display = main
                if let frame = r.orphanFrame { r.homeFrame = frame }
                r.orphanLayout = nil
                r.orphanFrame = nil
            }
        }
        guard let target = ensureLayout(id, on: uuid) else { return }
        model.update(token.key) { r in
            r.layout = target
            r.sticky = false
        }
        let nowVisible = model.record(token.key).map { model.isVisible($0, connected: connected, mainUUID: mainUUID) } ?? true
        suppressFocusSwitchUntil = Date().addingTimeInterval(0.5)
        syncPlacements { [weak self] in
            guard let self, wasFocused, !nowVisible else { return }
            if !self.focusMRU(on: uuid, excluding: token.key) { self.focusAwayFromParked() }
        }
        changed()
    }

    func setSticky(_ token: WindowToken, _ sticky: Bool) {
        guard let record = model.record(token.key), record.sticky != sticky else { return }
        let connected = connectedSet
        let main = mainUUID
        model.update(token.key) { r in
            r.sticky = sticky
            if !sticky {
                // Stays where the user sees it: the current layout of its display.
                if connected.contains(r.display) {
                    r.layout = model.current(on: r.display)
                } else if let main {
                    r.orphanLayout = model.current(on: main)
                }
            }
        }
        syncPlacements()
        changed()
    }

    func isSticky(_ token: WindowToken) -> Bool {
        model.record(token.key)?.sticky ?? false
    }

    func moveAllWindows(fromLayout: Int, toLayout: Int, on display: DisplayID) {
        let uuid = display.uuid
        guard status == .running, fromLayout != toLayout, (0...LayoutModel.maxLayoutId).contains(toLayout),
              model.hasLayout(fromLayout, on: uuid),
              let toLayout = ensureLayout(toLayout, on: uuid), toLayout != fromLayout else { return }
        let isMain = uuid == mainUUID
        for record in model.allRecords where !record.sticky {
            model.update(record.key) { r in
                if r.display == uuid, r.layout == fromLayout { r.layout = toLayout }
                if isMain, r.orphanLayout == fromLayout { r.orphanLayout = toLayout }
            }
        }
        suppressFocusSwitchUntil = Date().addingTimeInterval(0.5)
        syncPlacements()
        changed()
    }

    // MARK: Switching and focus

    private func performSwitch(to id: Int, on uuid: String, focusKey: String?, force: Bool = false,
                               refocus: Bool = true, launchApps: Bool = false) {
        // Only createLayout adds layouts. A switch to a missing layout does nothing.
        guard model.hasLayout(id, on: uuid) else { return }
        let previous = model.current(on: uuid)
        guard force || previous != id || focusKey != nil else { return }
        model.setCurrent(id, on: uuid)
        // Launch targets for a layout the user just left are dropped.
        pendingTargets = pendingTargets.filter { $0.value.display != uuid || $0.value.layout == id }
        if model.restoreArrangementOnSwitch { applyArrangement(id, on: uuid) }
        if launchApps { launchAppsToOpen(id, on: uuid) }
        // An empty, unnamed layout the user just left goes away (higher ones shift down).
        if previous != id, isDisposable(previous, on: uuid) { removeLayout(previous, on: uuid) }
        suppressFocusSwitchUntil = Date().addingTimeInterval(0.5)
        syncPlacements { [weak self] in
            guard let self else { return }
            if let focusKey, let record = self.model.record(focusKey) {
                self.suppressFocusSwitchUntil = Date().addingTimeInterval(0.5)
                Focus.focus(windowId: record.windowId, pid: record.pid, tracker: self.tracker)
            } else if refocus, !self.focusMRU(on: uuid, excluding: nil) {
                // Empty layout: do not leave keyboard focus in a window that is now parked.
                self.focusAwayFromParked()
            }
        }
        changed()
    }

    /// Focuses the most recently used shown window of the current layout on the display.
    /// Returns false when there is no window to focus.
    @discardableResult
    private func focusMRU(on uuid: String, excluding: String?) -> Bool {
        guard active else { return false }
        let connected = connectedSet
        let main = mainUUID
        let layout = model.current(on: uuid)
        func usable(_ key: String) -> WindowRecord? {
            guard key != excluding, let record = model.record(key),
                  let window = live[record.windowId], !window.isMinimized,
                  model.isVisible(record, connected: connected, mainUUID: main),
                  model.placement(of: record, connected: connected, mainUUID: main).display == uuid else { return nil }
            return record
        }
        var target = model.mru(layout, on: uuid).lazy.compactMap(usable).first
        if target == nil {
            // Most recently focused first, then left to right (then top to bottom) by frame.
            let members = model.allRecords.filter { usable($0.key) != nil }.sorted { a, b in
                let ta = lastFocusedAt[a.key] ?? .distantPast, tb = lastFocusedAt[b.key] ?? .distantPast
                if ta != tb { return ta > tb }
                let fa = live[a.windowId]?.frame ?? a.homeFrame.rect, fb = live[b.windowId]?.frame ?? b.homeFrame.rect
                if fa.minX != fb.minX { return fa.minX < fb.minX }
                if fa.minY != fb.minY { return fa.minY < fb.minY }
                return a.key < b.key
            }
            target = members.first { !$0.sticky } ?? members.first
        }
        guard let target else { return false }
        suppressFocusSwitchUntil = Date().addingTimeInterval(0.5)
        Focus.focus(windowId: target.windowId, pid: target.pid, tracker: tracker)
        return true
    }

    /// If the focused window is parked, hands focus to Finder (the desktop), so typing
    /// does not go to a hidden window. Focus events in the next second do not switch layouts.
    private func focusAwayFromParked() {
        guard active, let front = NSWorkspace.shared.frontmostApplication,
              let focused = focusedByPid[front.processIdentifier], parking.isParked(focused),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              finder.processIdentifier != front.processIdentifier else { return }
        suppressFocusSwitchUntil = Date().addingTimeInterval(1.0)
        finder.activate(options: .activateIgnoringOtherApps)
    }

    /// Focus moved to a window. If it is parked in another layout, switch to that layout.
    private func handleFocus(pid: pid_t, windowId: CGWindowID) {
        guard active else { return }
        let connected = connectedSet
        let main = mainUUID
        if let key = model.key(forWindowId: windowId), let record = model.record(key) {
            let placement = model.placement(of: record, connected: connected, mainUUID: main)
            lastMemberByPid[pid] = key
            lastFocusedAt[key] = Date()
            if model.isVisible(record, connected: connected, mainUUID: main) {
                lastFocusedDisplay = placement.display
                let before = model.mru(placement.layout, on: placement.display).first
                model.touchMRU(key, connected: connected, mainUUID: main)
                // The app order in the bar follows the MRU list.
                if before != key { notify() }
                return
            }
            if let placed = autoPlacedAt[windowId], Date().timeIntervalSince(placed) < 3 {
                // A rule or a launch put this new window into a hidden layout: keep the user where they are.
                let here = lastFocusedDisplay.flatMap { connected.contains($0) ? $0 : nil } ?? placement.display
                if !focusMRU(on: here, excluding: key) { focusAwayFromParked() }
                return
            }
            scheduleFocusSwitch(pid: pid, windowId: windowId) { [weak self] in
                guard let self, let record = self.model.record(key), record.windowId == windowId,
                      !self.model.isVisible(record, connected: self.connectedSet, mainUUID: self.mainUUID) else { return }
                let placement = self.model.placement(of: record, connected: self.connectedSet, mainUUID: self.mainUUID)
                self.lastFocusedDisplay = placement.display
                self.performSwitch(to: placement.layout, on: placement.display, focusKey: key)
            }
            return
        }
        // A dialog of an app whose last focused window is parked.
        guard followers[windowId] != nil, let leaderKey = lastMemberByPid[pid] else { return }
        scheduleFocusSwitch(pid: pid, windowId: windowId) { [weak self] in
            guard let self, let leader = self.model.record(leaderKey),
                  !self.model.isVisible(leader, connected: self.connectedSet, mainUUID: self.mainUUID) else { return }
            let placement = self.model.placement(of: leader, connected: self.connectedSet, mainUUID: self.mainUUID)
            // The dialog already has focus; only show its layout.
            self.performSwitch(to: placement.layout, on: placement.display, focusKey: nil, refocus: false)
        }
    }

    /// Waits 150 ms before a focus-driven switch. On Cmd-W the focus change can arrive before the
    /// close event, so the switch is dropped if that app closed something meanwhile or focus moved on.
    private func scheduleFocusSwitch(pid: pid_t, windowId: CGWindowID, _ perform: @escaping () -> Void) {
        guard Date() >= suppressFocusSwitchUntil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active, Date() >= self.suppressFocusSwitchUntil else { return }
            if let closed = self.lastCloseAt[pid], Date().timeIntervalSince(closed) < 0.6 { return }
            guard self.focusedByPid[pid] == windowId,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            perform()
        }
    }

    /// A window closed, minimized, or an app quit or hid. macOS now moves focus somewhere,
    /// maybe into a parked window: that must not switch layouts. Then focus the MRU window.
    private func noteClose(_ pid: pid_t) {
        guard active else { return }
        lastCloseAt[pid] = Date()
        let until = Date().addingTimeInterval(0.3)
        if until > suppressFocusSwitchUntil { suppressFocusSwitchUntil = until }
        let display = lastFocusedDisplay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.focusAfterClose(display: display)
        }
    }

    /// Only steps in when focus really landed in a parked window. Anything else (a system prompt
    /// such as Touch ID or a password sheet, a dialog, an app Desks does not track, no window at all)
    /// is left alone: taking focus from it would cancel it. A popup closing (Chrome autofill) also
    /// sends a destroyed event, so this runs often.
    private func focusAfterClose(display: String?) {
        guard active, let uuid = display.flatMap({ connectedSet.contains($0) ? $0 : nil }) ?? mainUUID else { return }
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let watcher = tracker.watcher(front) else { return }
        watcher.queue.async { [weak self] in
            let focused = AX.element(watcher.app, kAXFocusedWindowAttribute).flatMap(AX.windowId)
            DispatchQueue.main.async {
                guard let self, self.active, let focused,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == front,
                      self.model.record(forWindowId: focused) != nil, self.parking.isParked(focused) else { return }
                if !self.focusMRU(on: uuid, excluding: nil) { self.focusAwayFromParked() }
            }
        }
    }

    // MARK: Snapshots

    private func reconcile(_ snapshot: AppSnapshot) {
        guard active else { return }
        let pid = snapshot.pid
        if NSRunningApplication(processIdentifier: pid)?.isHidden == true { return }
        let settling = Date() < settleUntil
        var structural = false
        var seen = Set<CGWindowID>()
        var unknown: [LiveWindow] = []

        for window in snapshot.windows {
            let id = window.windowId
            seen.insert(id)
            if !legacyJournal.isEmpty, !Screens.looksParked(window.frame, in: screens) {
                legacyJournal.removeAll { $0.pid == pid && $0.windowId == id }
            }
            if let key = model.key(forWindowId: id) {
                live[id] = window
                followers[id] = nil
                if updateKnown(key, window, settling: settling) { structural = true }
            } else if window.isStandard, !window.isMinimized, window.frame.width >= 30, window.frame.height >= 30 {
                if ignored[id] != nil {
                    ignored[id] = window
                    retryReleasedShow(window)
                } else if waitForTitle(window) {
                    // A title rule may match once the app sets the title. Read again soon.
                    tracker.refresh(pid, after: 1.05)
                } else if case .ignore? = matchRule(bundleId: window.bundleId, title: window.title)?.action {
                    ignored[id] = window
                    firstSeen[id] = nil
                } else {
                    unknown.append(window)
                    firstSeen[id] = nil
                }
            } else if window.isFollower {
                followers[id] = window
                if !settling, !parking.isInTransit(id), !parking.isParked(id), !Screens.looksParked(window.frame, in: screens) {
                    followerHome[id] = window.frame
                }
            } else {
                followers[id] = nil
            }
        }
        if !unknown.isEmpty {
            adopt(unknown, bundleId: snapshot.bundleId)
            structural = true
        }

        if snapshot.complete {
            let missing = model.allRecords.filter { $0.pid == pid && !seen.contains($0.windowId) }
            if !missing.isEmpty {
                // Windows on another Space or in full screen are not in the AX list but still exist.
                let existing = WindowTracker.existingWindowIds(for: pid)
                if missing.contains(where: { !existing.contains($0.windowId) }) {
                    // A close we did not hear about (the destroyed event is not reliable).
                    noteClose(pid)
                }
                for record in missing {
                    live[record.windowId] = nil
                    if !existing.contains(record.windowId) {
                        model.remove(record.key)
                        parking.forget(record.windowId)
                        forceHome.remove(record.windowId)
                        showRetry[record.windowId] = nil
                        if lastMemberByPid[pid] == record.key { lastMemberByPid[pid] = nil }
                        structural = true
                    }
                }
            }
            for (id, follower) in followers where follower.pid == pid && !seen.contains(id) {
                followers[id] = nil
                followerHome[id] = nil
                parking.forget(id)
            }
            for (id, window) in ignored where window.pid == pid && !seen.contains(id) { ignored[id] = nil }
        }

        let focusChanged = focusedByPid[pid] != snapshot.focusedWindowId
        focusedByPid[pid] = snapshot.focusedWindowId
        // While displays settle, screen frames may be stale; applyScreenChange syncs after.
        if !settling { syncPlacements() }
        if structural {
            writeJournal()
            changed()
        } else {
            if framesDirty { scheduleSave() }
            // The full-screen flag of a display depends on the focused window.
            if focusChanged { notify() }
        }

        // Only a real focus change (or an app activation, such as Cmd-Tab) may switch layouts.
        // A poll that sees the same focused window must not undo the user's switch.
        let activated = activatedPids.remove(pid) != nil
        if focusChanged || activated, let focused = snapshot.focusedWindowId,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            handleFocus(pid: pid, windowId: focused)
        }
    }

    /// Updates a known window from live data. Returns true when membership changed.
    private func updateKnown(_ key: String, _ window: LiveWindow, settling: Bool) -> Bool {
        let id = window.windowId
        model.update(key) { r in
            if !window.title.isEmpty { r.title = window.title }
            if !window.subrole.isEmpty { r.role = window.subrole }
            if window.index >= 0 { r.index = window.index }
            r.pid = window.pid
        }
        guard !settling, !window.isMinimized, !window.isFullScreen, !parking.isInTransit(id) else { return false }

        // Parked, but it came back on screen by itself (some apps jump back). Park it again, a few times at most.
        if case .parked(let point)? = parking.applied[id] {
            showRetry[id] = nil
            let moved = abs(window.frame.minX - point.x) > 4 || abs(window.frame.minY - point.y) > 4
            if moved, !Screens.looksParked(window.frame, in: screens) { parking.requestRepark(id) }
            return false
        }
        // Shown, but still in a corner: the show did not land (slow app). Show it again, a few times at most.
        if parking.applied[id] == .visible, Screens.looksParked(window.frame, in: screens) {
            if showRetry[id, default: 0] < 3 {
                showRetry[id, default: 0] += 1
                forceHome.insert(id)
            }
            return false
        }
        if parking.applied[id] == .visible { showRetry[id] = nil }
        guard parking.applied[id] == .visible, !Screens.looksParked(window.frame, in: screens),
              let screen = Screens.screen(for: window.frame, in: screens),
              let record = model.record(key) else { return false }
        let connected = connectedSet
        let target = screen.id.uuid
        if !connected.contains(record.display) {
            if target == mainUUID {
                if record.orphanFrame?.rect != window.frame {
                    model.update(key) { $0.orphanFrame = StoredFrame(window.frame) }
                    framesDirty = true
                }
                return false
            }
            // An orphan dragged to another connected display joins it.
            model.update(key) { r in
                r.display = target
                if !r.sticky { r.layout = model.current(on: target) }
                r.orphanLayout = nil
                r.orphanFrame = nil
                r.homeFrame = StoredFrame(window.frame)
            }
            return true
        }
        if target != record.display {
            // Dragged to another display: it joins that display's current layout.
            model.update(key) { r in
                r.display = target
                if !r.sticky { r.layout = model.current(on: target) }
                r.homeFrame = StoredFrame(window.frame)
            }
            model.touchMRU(key, connected: connected, mainUUID: mainUUID)
            return true
        }
        if record.homeFrame.rect != window.frame || record.homeUnknown == true {
            model.update(key) { r in
                r.homeFrame = StoredFrame(window.frame)
                r.homeUnknown = nil
            }
            framesDirty = true
        }
        return false
    }

    /// New standard windows: match saved fingerprints first, else join the current layout of their display.
    private func adopt(_ windows: [LiveWindow], bundleId: String) {
        let now = Date()
        pendingSaved.removeAll { $0.until < now }
        autoPlacedAt = autoPlacedAt.filter { now.timeIntervalSince($0.value) < 10 }
        // A launch target is used by the app's first window only, matched or new. Taken here, so a
        // restored (matched) window also uses it up and a later Cmd-N joins the current layout.
        var launchTarget = takePendingTarget(bundleId)
        let connected = connectedSet
        let main = mainUUID

        var pairs: [(score: Int, window: Int, saved: Int)] = []
        for (wi, window) in windows.enumerated() {
            for (si, entry) in pendingSaved.enumerated() where entry.record.bundleId == bundleId {
                let s = Self.matchScore(entry.record, window)
                if s > 3 { pairs.append((s, wi, si)) }
            }
        }
        pairs.sort { $0.score > $1.score }
        var usedWindows = Set<Int>()
        var usedSaved = Set<Int>()
        var matched: [Int: WindowRecord] = [:]
        for pair in pairs where !usedWindows.contains(pair.window) && !usedSaved.contains(pair.saved) {
            usedWindows.insert(pair.window)
            usedSaved.insert(pair.saved)
            matched[pair.window] = pendingSaved[pair.saved].record
        }
        pendingSaved = pendingSaved.enumerated().filter { !usedSaved.contains($0.offset) }.map(\.element)

        for (wi, window) in windows.enumerated() {
            let id = window.windowId
            live[id] = window
            let looksParked = Screens.looksParked(window.frame, in: screens)
            if var record = matched[wi] {
                record.windowId = id
                record.pid = window.pid
                if !window.title.isEmpty { record.title = window.title }
                if window.index >= 0 { record.index = window.index }
                if !looksParked, !window.isFullScreen {
                    record.homeFrame = StoredFrame(window.frame)
                    record.homeUnknown = nil
                }
                if connected.contains(record.display) {
                    if !model.hasLayout(record.layout, on: record.display) { record.layout = 0 }
                    record.orphanLayout = nil
                    record.orphanFrame = nil
                } else if let main {
                    if record.orphanLayout == nil || !model.hasLayout(record.orphanLayout!, on: main) {
                        record.orphanLayout = model.current(on: main)
                    }
                    if !looksParked { record.orphanFrame = StoredFrame(window.frame) }
                }
                model.upsert(record)
            } else {
                guard let screen = Screens.screen(for: window.frame, in: screens) ?? screens.first else { continue }
                // A window that opens in a corner (for example restored after a crash) is brought back to the middle.
                var home = looksParked ? Screens.sanitize(window.frame, target: screen, screens: screens) : window.frame
                var display = screen.id.uuid
                var layout = model.current(on: display)
                var sticky = false
                // Order: a launch for a layout, then rules, then the current layout.
                if releasedFromIgnore.remove(id) != nil {
                    // Let back in after its ignore rule went away: current layout, no rules.
                } else if let target = launchTarget, let targetScreen = self.screen(target.display) {
                    launchTarget = nil
                    display = target.display
                    layout = ensureLayout(target.layout, on: display) ?? layout
                    home = Screens.fit(home, into: targetScreen)
                } else if let rule = matchRule(bundleId: bundleId, title: window.title) {
                    switch rule.action {
                    case .layout(let n) where (0...LayoutModel.maxLayoutId).contains(n):
                        layout = ensureLayout(n, on: display) ?? layout
                    case .sticky:
                        sticky = true
                    case .layout, .ignore:
                        break
                    }
                }
                if !sticky, layout != model.current(on: display) { autoPlacedAt[id] = now }
                model.upsert(WindowRecord(
                    key: UUID().uuidString, bundleId: bundleId, title: window.title, role: window.subrole,
                    index: max(window.index, 0), display: display, layout: layout,
                    sticky: sticky, homeFrame: StoredFrame(home), windowId: id, pid: window.pid,
                    orphanLayout: nil, orphanFrame: nil,
                    // First seen in full screen: the real home frame is captured when it leaves full screen.
                    homeUnknown: window.isFullScreen ? true : nil))
            }
        }
    }

    /// Fingerprint score from PLAN section 5. Same window id and pid (Desks relaunched, app kept running) wins.
    private static func matchScore(_ saved: WindowRecord, _ window: LiveWindow) -> Int {
        var score = 0
        if saved.windowId == window.windowId, saved.pid == window.pid { score += 10 }
        if !saved.title.isEmpty, saved.title == window.title { score += 3 }
        if saved.role == window.subrole { score += 1 }
        let a = saved.homeFrame.rect, b = window.frame
        if abs(a.minX - b.minX) <= 40, abs(a.minY - b.minY) <= 40,
           abs(a.width - b.width) <= 40, abs(a.height - b.height) <= 40 { score += 2 }
        if saved.index == window.index { score += 1 }
        return score
    }

    private func appGone(_ pid: pid_t) {
        let records = model.allRecords.filter { $0.pid == pid }
        let until = Date().addingTimeInterval(600)
        for record in records {
            model.remove(record.key)
            parking.forget(record.windowId)
            live[record.windowId] = nil
            forceHome.remove(record.windowId)
            // Kept for a while, so the windows return to their layouts if the app opens again.
            pendingSaved.append((record, until))
        }
        for (id, follower) in followers where follower.pid == pid {
            followers[id] = nil
            followerHome[id] = nil
            parking.forget(id)
        }
        lastMemberByPid[pid] = nil
        focusedByPid[pid] = nil
        activatedPids.remove(pid)
        legacyJournal.removeAll { $0.pid == pid }
        ignored = ignored.filter { $0.value.pid != pid }
        if active { noteClose(pid) }
        writeJournal()
        changed()
    }

    private func parked(_ id: CGWindowID, frameBefore: CGRect) {
        guard !Screens.looksParked(frameBefore, in: screens) else { return }
        if let key = model.key(forWindowId: id), let record = model.record(key) {
            if connectedSet.contains(record.display) {
                model.update(key) { r in
                    r.homeFrame = StoredFrame(frameBefore)
                    r.homeUnknown = nil
                }
            } else {
                model.update(key) { $0.orphanFrame = StoredFrame(frameBefore) }
            }
            scheduleSave()
        } else if followers[id] != nil {
            followerHome[id] = frameBefore
        }
        writeJournal()
    }

    // MARK: Placement

    private func syncPlacements(completion: (() -> Void)? = nil) {
        guard active else { completion?(); return }
        let connected = connectedSet
        let main = mainUUID
        var desires: [Desire] = []
        for record in model.allRecords {
            guard let window = live[record.windowId], !window.isMinimized, !window.isFullScreen else { continue }
            let placement = model.placement(of: record, connected: connected, mainUUID: main)
            guard let screen = screen(placement.display) ?? screens.first else { continue }
            let orphan = !connected.contains(record.display)
            var rawHome = (orphan ? record.orphanFrame?.rect : nil) ?? record.homeFrame.rect
            // No real home yet (only seen in full screen): its own frame is the best guess.
            if record.homeUnknown == true { rawHome = window.frame }
            desires.append(desire(window, visible: model.isVisible(record, connected: connected, mainUUID: main),
                                  home: rawHome, screen: screen))
        }
        for (id, follower) in followers {
            guard let leaderKey = lastMemberByPid[follower.pid], let leader = model.record(leaderKey) else {
                // No leader known: never parked. Bring it back if we parked it before.
                if parking.isParked(id) {
                    let screen = Screens.screen(for: followerHome[id] ?? follower.frame, in: screens) ?? screens.first
                    if let screen { desires.append(desire(follower, visible: true, home: followerHome[id] ?? follower.frame, screen: screen)) }
                }
                continue
            }
            let placement = model.placement(of: leader, connected: connected, mainUUID: main)
            guard let screen = screen(placement.display) ?? screens.first else { continue }
            desires.append(desire(follower, visible: model.isVisible(leader, connected: connected, mainUUID: main),
                                  home: followerHome[id] ?? follower.frame, screen: screen))
        }
        for d in desires { forceHome.remove(d.window.windowId) }
        parking.sync(desires, beforePark: { [weak self] in self?.writeJournal() }, completion: completion)
    }

    private func desire(_ window: LiveWindow, visible: Bool, home: CGRect, screen: ScreenInfo) -> Desire {
        let corner = corners[screen.id] ?? .bottomRight
        return Desire(
            window: window, visible: visible,
            home: Screens.sanitize(home, target: screen, screens: screens),
            parkPoint: Screens.parkPoint(on: screen, corner: corner, windowSize: window.frame.size, bundleId: window.bundleId),
            looksParked: Screens.looksParked(window.frame, in: screens),
            forceHome: forceHome.contains(window.windowId))
    }

    /// Frames to restore every window we parked.
    private func parkedTargets() -> [(pid: pid_t, windowId: CGWindowID, frame: CGRect)] {
        let connected = connectedSet
        var targets: [(pid: pid_t, windowId: CGWindowID, frame: CGRect)] = []
        for (id, placement) in parking.applied {
            guard case .parked = placement else { continue }
            if let record = model.record(forWindowId: id) {
                let display = model.placement(of: record, connected: connected, mainUUID: mainUUID).display
                guard let screen = screen(display) ?? screens.first else { continue }
                let orphan = !connected.contains(record.display)
                let raw = (orphan ? record.orphanFrame?.rect : nil) ?? record.homeFrame.rect
                targets.append((record.pid, id, Screens.sanitize(raw, target: screen, screens: screens)))
            } else if let follower = followers[id], let home = followerHome[id] {
                guard let screen = Screens.screen(for: home, in: screens) else { continue }
                targets.append((follower.pid, id, Screens.sanitize(home, target: screen, screens: screens)))
            }
        }
        return targets
    }

    // MARK: Journal and rescue

    /// Writes every parked window with its home frame, plus old entries not restored yet.
    /// Called before any park is sent.
    private func writeJournal() {
        var entries = journalEntries()
        let ids = Set(entries.map(\.windowId))
        entries.append(contentsOf: legacyJournal.filter { !ids.contains($0.windowId) })
        store.writeJournal(entries)
    }

    /// Every window we parked in this session, with its home frame.
    private func journalEntries() -> [JournalEntry] {
        let connected = connectedSet
        var entries: [JournalEntry] = []
        for (id, placement) in parking.applied {
            guard case .parked = placement else { continue }
            if let record = model.record(forWindowId: id) {
                let orphan = !connected.contains(record.display)
                let home = (orphan ? record.orphanFrame : nil) ?? record.homeFrame
                entries.append(JournalEntry(pid: record.pid, bundleId: record.bundleId, windowId: id,
                                            title: record.title, homeFrame: home))
            } else if let follower = followers[id], let home = followerHome[id] {
                entries.append(JournalEntry(pid: follower.pid, bundleId: follower.bundleId, windowId: id,
                                            title: follower.title, homeFrame: StoredFrame(home)))
            }
        }
        return entries
    }

    /// After a crash: moves every window from the last journal back to its home frame.
    /// Runs on each app's queue before the first snapshot, so matching sees the restored frames.
    /// Entries whose move could not be verified stay in the journal. Entries of apps that are not
    /// running are dropped: their windows are gone, and a window that reopens in a corner is
    /// brought back by adopt().
    private func rescueFromJournal() {
        let entries = store.loadJournal()
        guard !entries.isEmpty else { return }
        let screens = self.screens
        var byPid: [pid_t: [JournalEntry]] = [:]
        for entry in entries {
            var pid: pid_t?
            if let app = NSRunningApplication(processIdentifier: entry.pid), app.bundleIdentifier == entry.bundleId {
                pid = entry.pid
            } else {
                pid = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleId).first?.processIdentifier
            }
            if let pid, tracker.watcher(pid) != nil { byPid[pid, default: []].append(entry) }
        }
        legacyJournal = byPid.values.flatMap { $0 }
        writeJournal()
        for (pid, list) in byPid {
            guard let watcher = tracker.watcher(pid) else { continue }
            watcher.queue.async { [weak self] in
                var used = Set<CGWindowID>()
                var leftovers: [JournalEntry] = []
                let elements = watcher.allElements().map { (id: $0.0, element: $0.1, frame: AX.frame($0.1)) }
                for entry in list {
                    let samePid = entry.pid == pid
                    let parkedOnes = elements.filter { item in
                        !used.contains(item.id) && item.frame.map { Screens.looksParked($0, in: screens) } == true
                    }
                    let hit = (samePid ? parkedOnes.first { $0.id == entry.windowId } : nil)
                        ?? parkedOnes.first { !entry.title.isEmpty && AX.string($0.element, kAXTitleAttribute) == entry.title }
                        ?? parkedOnes.first
                    // No window of this app sits in a corner: nothing left to restore.
                    guard let hit, let target = Screens.screen(for: entry.homeFrame.rect, in: screens) ?? screens.first else { continue }
                    used.insert(hit.id)
                    let frame = Screens.sanitize(entry.homeFrame.rect, target: target, screens: screens)
                    if !ParkingEngine.show(hit.id, at: frame, watcher: watcher) {
                        var kept = entry
                        kept.pid = pid
                        kept.windowId = hit.id
                        leftovers.append(kept)
                    }
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.legacyJournal.removeAll { list.contains($0) }
                    self.legacyJournal.append(contentsOf: leftovers)
                    if self.active { self.writeJournal() }
                }
            }
        }
    }

    /// Emergency: any window of any regular app that sits in a corner is moved to the middle of its display.
    private func rescueStrays() {
        guard AX.isTrusted() else { return }
        let screens = self.screens
        let managed = Set(model.allRecords.map(\.windowId)).union(followers.keys)
        let me = ProcessInfo.processInfo.processIdentifier
        let skipManaged = active
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            let pid = app.processIdentifier
            let job: (AXUIElement) -> Void = { axApp in
                AX.setTimeout(axApp)
                for element in AX.elements(axApp, kAXWindowsAttribute) ?? [] {
                    guard let id = AX.windowId(element), !skipManaged || !managed.contains(id),
                          let frame = AX.frame(element), Screens.looksParked(frame, in: screens),
                          let screen = Screens.screen(for: frame, in: screens) ?? screens.first else { continue }
                    let target = Screens.sanitize(frame, target: screen, screens: screens)
                    AX.withEnhancedUIOff(axApp) {
                        AX.setPosition(element, target.origin)
                    }
                }
            }
            if let watcher = tracker.watcher(pid) {
                watcher.queue.async { job(watcher.app) }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { job(AXUIElementCreateApplication(pid)) }
            }
        }
    }

    // MARK: Displays

    private var connectedSet: Set<String> { Set(screens.map(\.id.uuid)) }
    private var mainUUID: String? { screens.first?.id.uuid }

    private func screen(_ uuid: String) -> ScreenInfo? { screens.first { $0.id.uuid == uuid } }

    private func resolveDisplay(_ display: DisplayID?) -> String? {
        if let display, screen(display.uuid) != nil { return display.uuid }
        if let focused = focusedDisplay() { return focused.uuid }
        if let last = lastFocusedDisplay, screen(last) != nil { return last }
        return mainUUID
    }

    private func refreshScreens() {
        screens = Screens.current()
        for screen in screens { model.ensureDisplay(screen.id.uuid, label: screen.name) }
        let result = Screens.parkCorners(screens, option: options.parkCorner)
        corners = result.corners
        blockedScreens = result.blocked
        updateWarnings()
    }

    private func screensChanged() {
        settleUntil = Date().addingTimeInterval(2.5)
        screenChangeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.applyScreenChange() }
        screenChangeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// After a display change or wake: re-read displays, keep membership, handle unplugged and returned displays.
    private func applyScreenChange() {
        refreshScreens()
        let connected = connectedSet
        if let main = mainUUID {
            for record in model.allRecords {
                if !connected.contains(record.display) {
                    if record.orphanLayout == nil {
                        model.update(record.key) { $0.orphanLayout = model.current(on: main); $0.orphanFrame = nil }
                    }
                } else if record.orphanLayout != nil || record.orphanFrame != nil {
                    // Its display is back: return it to its own display, layout and frame.
                    model.update(record.key) { $0.orphanLayout = nil; $0.orphanFrame = nil }
                    forceHome.insert(record.windowId)
                }
            }
        }
        if active {
            tracker.refreshAll(after: 0)
            syncPlacements()
        }
        changed()
    }

    private func buildDisplays() -> [DisplayState] {
        let connected = connectedSet
        let main = mainUUID
        var fullScreenDisplay: String?
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let id = focusedByPid[pid], let window = live[id] ?? followers[id], window.isFullScreen {
            fullScreenDisplay = Screens.screen(for: window.frame, in: screens)?.id.uuid
        }
        return screens.map { screen in
            let uuid = screen.id.uuid
            let layouts = model.layouts(on: uuid).map { layout in
                LayoutInfo(id: layout.id, name: layout.name,
                           windowCount: model.windowCount(layout.id, on: uuid, connected: connected, mainUUID: main),
                           apps: model.apps(layout.id, on: uuid, connected: connected, mainUUID: main))
            }
            return DisplayState(display: screen.id, name: screen.name, visibleFrame: screen.visibleFrameAppKit,
                                layouts: layouts, current: model.current(on: uuid),
                                isFullScreenActive: fullScreenDisplay == uuid)
        }
    }

    private func updateWarnings() {
        var list: [String] = []
        if SystemState.isStageManagerOn() {
            list.append("Stage Manager is on. Desks keeps working, but it works best with Stage Manager off (System Settings > Desktop & Dock).")
        }
        for screen in blockedScreens {
            list.append("\(screen.name) has no free bottom corner, so parked windows may show on a neighbour display. Change the display arrangement or the park corner.")
        }
        for rule in invalidRules {
            let reason = RulePattern.problem(rule.titlePattern ?? "") ?? "Not a valid regular expression."
            list.append("A rule for \(rule.bundleID) is skipped. \(reason)")
        }
        if let bad = store.badStateFile {
            list.append("Saved layouts could not be read, so Desks started fresh. The old file was kept as \(bad) in ~/Library/Application Support/Desks.")
        }
        if PrivateAPI.getWindow == nil {
            list.append("A macOS call Desks needs to tell windows apart is missing. Windows cannot be managed on this macOS version.")
        }
        if list != warnings {
            warnings = list
            notify()
        }
    }

    // MARK: Change and save

    private func snapshotState() -> ModelState {
        let now = Date()
        return model.snapshot(pendingSaved: pendingSaved.filter { $0.until > now }.map(\.record))
    }

    private func scheduleSave() {
        framesDirty = false
        store.scheduleSave { [weak self] in self?.snapshotState() ?? ModelState() }
    }

    private func changed() {
        scheduleSave()
        notify()
    }

    /// Calls onChange once, on the main thread, after the current run loop turn.
    private func notify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onChange?()
        }
    }
}

// MARK: - v1.1: rules, apps to open, arrangements

extension LiveEngine {
    var rules: [WindowRule] {
        get { model.rules }
        set {
            guard newValue != model.rules else { return }
            model.rules = newValue
            compileRules()
            releaseNoLongerIgnored()
            updateWarnings()
            changed()
        }
    }

    var restoreArrangementOnSwitch: Bool {
        get { model.restoreArrangementOnSwitch }
        set {
            guard newValue != model.restoreArrangementOnSwitch else { return }
            model.restoreArrangementOnSwitch = newValue
            changed()
        }
    }

    /// Runs the rules over windows Desks already manages (and over ignored ones, so an
    /// ignore rule that was removed lets its windows back in).
    func applyRulesToExistingWindows() {
        let connected = connectedSet
        let main = mainUUID
        for record in model.allRecords {
            let title = live[record.windowId]?.title ?? record.title
            guard let rule = matchRule(bundleId: record.bundleId, title: title) else { continue }
            switch rule.action {
            case .layout(let n):
                guard (0...LayoutModel.maxLayoutId).contains(n),
                      let target = ensureLayout(n, on: record.display) else { continue }
                model.update(record.key) { r in
                    r.layout = target
                    r.sticky = false
                }
            case .sticky:
                model.update(record.key) { $0.sticky = true }
            case .ignore:
                let display = model.placement(of: record, connected: connected, mainUUID: main).display
                if let screen = screen(display) ?? screens.first {
                    let orphan = !connected.contains(record.display)
                    let raw = (orphan ? record.orphanFrame?.rect : nil) ?? record.homeFrame.rect
                    let home = Screens.sanitize(raw, target: screen, screens: screens)
                    let id = record.windowId
                    if parking.isParked(id) {
                        // Keep it in the journal until it is seen on screen, so a failed show is never lost.
                        legacyJournal.removeAll { $0.windowId == id }
                        legacyJournal.append(JournalEntry(pid: record.pid, bundleId: record.bundleId, windowId: id,
                                                          title: record.title, homeFrame: StoredFrame(home)))
                    }
                    parking.release(id, pid: record.pid, home: home) { [weak self] ok in
                        guard let self, ok else { return }
                        self.legacyJournal.removeAll { $0.windowId == id }
                        if self.active { self.writeJournal() }
                    }
                } else {
                    parking.forget(record.windowId)
                }
                if let window = live[record.windowId] { ignored[record.windowId] = window }
                live[record.windowId] = nil
                forceHome.remove(record.windowId)
                model.remove(record.key)
            }
        }
        // Ignored windows whose rule is gone or changed join on the next snapshot.
        for (id, window) in ignored {
            if case .ignore? = matchRule(bundleId: window.bundleId, title: window.title)?.action { continue }
            ignored[id] = nil
            tracker.refresh(window.pid, after: 0)
        }
        syncPlacements()
        writeJournal()
        changed()
    }

    func appsToOpen(layout id: Int, on display: DisplayID) -> [String] {
        model.appsToOpen(id, on: display.uuid)
    }

    func setAppsToOpen(_ bundleIDs: [String], layout id: Int, on display: DisplayID) {
        guard model.hasLayout(id, on: display.uuid) else { return }
        model.setAppsToOpen(bundleIDs, id, on: display.uuid)
        changed()
    }

    /// Pins the frames of the layout's windows. Shown windows use their live frame, parked ones their home frame.
    func saveArrangement(layout id: Int, on display: DisplayID) {
        let uuid = display.uuid
        guard model.hasLayout(id, on: uuid) else { return }
        let connected = connectedSet
        let main = mainUUID
        var frames: [String: StoredFrame] = [:]
        for record in model.allRecords where !record.sticky {
            let placement = model.placement(of: record, connected: connected, mainUUID: main)
            guard placement.display == uuid, placement.layout == id else { continue }
            let orphan = !connected.contains(record.display)
            var frame = (orphan ? record.orphanFrame : nil) ?? record.homeFrame
            if let window = live[record.windowId], parking.applied[record.windowId] == .visible,
               !window.isMinimized, !window.isFullScreen, !Screens.looksParked(window.frame, in: screens) {
                frame = StoredFrame(window.frame)
            }
            frames[record.key] = frame
        }
        model.setArrangement(frames, id, on: uuid)
        changed()
    }

    func restoreArrangement(layout id: Int, on display: DisplayID) {
        guard model.hasLayout(id, on: display.uuid) else { return }
        applyArrangement(id, on: display.uuid)
        syncPlacements()
        changed()
    }

    func hasSavedArrangement(layout id: Int, on display: DisplayID) -> Bool {
        !model.arrangement(id, on: display.uuid).isEmpty
    }

    // MARK: Helpers

    /// The layout to use for a requested id: the id itself if it exists, else one layout added at
    /// the end (never a gap). Returns nil when all 10 layouts exist and the id is missing.
    fileprivate func ensureLayout(_ id: Int, on uuid: String) -> Int? {
        if model.hasLayout(id, on: uuid) { return id }
        if let made = createdFor[uuid]?[id], model.hasLayout(made, on: uuid) { return made }
        guard let made = model.appendLayout(on: uuid) else { return nil }
        createdFor[uuid, default: [:]][id] = made
        return made
    }

    /// Removed automatically when left: not the first layout, no windows (sticky ones do not count,
    /// saved windows waiting for their app do), default name, nothing pinned or launched, no rule target.
    fileprivate func isDisposable(_ id: Int, on uuid: String) -> Bool {
        guard id != 0, let layout = model.layoutRecord(id, on: uuid), model.isDefaultAndUnused(layout),
              model.windowCount(id, on: uuid, connected: connectedSet, mainUUID: mainUUID) == 0 else { return false }
        return !pendingSaved.contains { !$0.record.sticky && $0.record.display == uuid && $0.record.layout == id }
    }

    /// Removes a layout and shifts everything keyed by layout id on that display.
    fileprivate func removeLayout(_ id: Int, on uuid: String) {
        let main = mainUUID
        guard model.removeLayout(id, on: uuid, mainUUID: main) else { return }
        for i in pendingSaved.indices {
            if pendingSaved[i].record.display == uuid {
                pendingSaved[i].record.layout = LayoutModel.shifted(pendingSaved[i].record.layout, removing: id)
            }
            if uuid == main, let orphan = pendingSaved[i].record.orphanLayout {
                pendingSaved[i].record.orphanLayout = LayoutModel.shifted(orphan, removing: id)
            }
        }
        var targets: [String: (display: String, layout: Int, until: Date)] = [:]
        for (bundleId, target) in pendingTargets {
            if target.display != uuid { targets[bundleId] = target; continue }
            if target.layout == id { continue }
            targets[bundleId] = (target.display, LayoutModel.shifted(target.layout, removing: id), target.until)
        }
        pendingTargets = targets
        createdFor[uuid] = nil
        compileRules()
    }

    /// Sets pinned frames as home frames. Windows without a pin, sticky windows and windows that
    /// left the layout are not touched. Shown windows move at the next sync.
    fileprivate func applyArrangement(_ id: Int, on uuid: String) {
        let connected = connectedSet
        let main = mainUUID
        for (key, frame) in model.arrangement(id, on: uuid) {
            guard let record = model.record(key), !record.sticky else { continue }
            let placement = model.placement(of: record, connected: connected, mainUUID: main)
            guard placement.display == uuid, placement.layout == id else { continue }
            if connected.contains(record.display) {
                model.update(key) { $0.homeFrame = frame }
            } else {
                model.update(key) { $0.orphanFrame = frame }
            }
            if model.isVisible(record, connected: connected, mainUUID: main) { forceHome.insert(record.windowId) }
        }
    }

    /// Launches the layout's apps that are not running, without activating them.
    fileprivate func launchAppsToOpen(_ id: Int, on uuid: String) {
        let until = Date().addingTimeInterval(15)
        for bundleId in model.appsToOpen(id, on: uuid) {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { continue }
            pendingTargets[bundleId] = (uuid, id, until)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
    }

    /// The layout an app was launched for, once (its first new window), within 15 seconds.
    fileprivate func takePendingTarget(_ bundleId: String) -> (display: String, layout: Int)? {
        let now = Date()
        pendingTargets = pendingTargets.filter { $0.value.until > now }
        guard let target = pendingTargets.removeValue(forKey: bundleId) else { return nil }
        return (target.display, target.layout)
    }

    static let maxTitleLength = 512

    /// Compiles title patterns once per rule. Patterns RulePattern.problem rejects (invalid, too long,
    /// or risky repetition that can take forever on the main thread) are skipped with a warning.
    fileprivate func compileRules() {
        compiledPatterns = [:]
        invalidRules = []
        for rule in model.rules {
            guard let pattern = rule.titlePattern, !pattern.isEmpty else { continue }
            guard RulePattern.problem(pattern) == nil,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                invalidRules.append(rule)
                continue
            }
            compiledPatterns[rule.id] = regex
        }
    }

    /// First enabled rule for the app whose title pattern matches. Rules with a bad pattern are skipped.
    fileprivate func matchRule(bundleId: String, title: String) -> WindowRule? {
        for rule in model.rules where rule.enabled && rule.bundleID == bundleId {
            if let pattern = rule.titlePattern, !pattern.isEmpty {
                guard let regex = compiledPatterns[rule.id] else { continue }
                let text = String(title.prefix(Self.maxTitleLength))
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) == nil { continue }
            }
            return rule
        }
        return nil
    }

    /// After a rule edit: windows whose ignore rule no longer matches are let back in. They join the
    /// current layout of their display (rules do not run for them). One still in a corner from an
    /// earlier release is shown again first (verified, kept in the journal until seen on screen).
    fileprivate func releaseNoLongerIgnored() {
        for (id, window) in ignored {
            if case .ignore? = matchRule(bundleId: window.bundleId, title: window.title)?.action { continue }
            if Screens.looksParked(window.frame, in: screens) {
                showRetry[id] = nil
                retryReleasedShow(window)
            }
            ignored[id] = nil
            releasedFromIgnore.insert(id)
            tracker.refresh(window.pid, after: 0)
        }
    }

    /// An ignored window that we released but that still sits in a corner: show it again, a few times at most.
    fileprivate func retryReleasedShow(_ window: LiveWindow) {
        let id = window.windowId
        guard let entry = legacyJournal.first(where: { $0.windowId == id && $0.pid == window.pid }),
              Screens.looksParked(window.frame, in: screens), showRetry[id, default: 0] < 3,
              let watcher = tracker.watcher(window.pid) else { return }
        showRetry[id, default: 0] += 1
        let home = entry.homeFrame.rect
        watcher.queue.async { [weak self] in
            let ok = ParkingEngine.show(id, at: home, watcher: watcher)
            DispatchQueue.main.async {
                guard let self, ok else { return }
                self.legacyJournal.removeAll { $0.windowId == id }
                self.showRetry[id] = nil
                if self.active { self.writeJournal() }
            }
        }
    }

    /// True for about one second for a new untitled window whose app has a title rule.
    fileprivate func waitForTitle(_ window: LiveWindow) -> Bool {
        guard window.title.isEmpty,
              model.rules.contains(where: { $0.enabled && $0.bundleID == window.bundleId && !($0.titlePattern ?? "").isEmpty })
        else { return false }
        let now = Date()
        firstSeen = firstSeen.filter { now.timeIntervalSince($0.value) < 30 }
        let first = firstSeen[window.windowId] ?? now
        firstSeen[window.windowId] = first
        return now.timeIntervalSince(first) < 1.0
    }
}

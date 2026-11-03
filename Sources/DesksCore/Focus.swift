import AppKit
import ApplicationServices

enum Focus {
    /// Focuses one window: AXMain and AXRaise on the app's queue, then activate the app on main.
    /// If the app did not come to the front, falls back to the private SkyLight call.
    /// Order taken from AeroSpace (MIT): raise first, so the window is on top when the app activates.
    /// If another app comes to the front meanwhile (a Touch ID prompt, the user's own click), it is left alone.
    static func focus(windowId: CGWindowID, pid: pid_t, tracker: WindowTracker) {
        guard let watcher = tracker.watcher(pid) else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let frontAtStart = NSWorkspace.shared.frontmostApplication?.processIdentifier
        /// False when the front app changed to some other app. When Desks itself was front (the move
        /// overlay), it is handing focus back, so any change is fine.
        func frontStillOurs() -> Bool {
            guard let start = frontAtStart, start != me else { return true }
            let now = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return now == start || now == pid
        }
        watcher.queue.async {
            if let element = watcher.element(for: windowId) {
                AX.setBool(element, kAXMainAttribute, true)
                AX.raise(element)
            }
            DispatchQueue.main.async {
                guard frontStillOurs() else { return }
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, frontStillOurs() else { return }
                    watcher.queue.async {
                        PrivateAPI.bringToFront(pid: pid, windowId: windowId)
                        if let element = watcher.element(for: windowId) { AX.raise(element) }
                    }
                }
            }
        }
    }
}

enum SystemState {
    /// Stage Manager flag from the WindowManager preferences domain.
    static func isStageManagerOn() -> Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }
}

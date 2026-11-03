import AppKit
import ApplicationServices

enum Focus {
    /// Focuses one window: AXMain and AXRaise on the app's queue, then activate the app on main.
    /// If the app did not come to the front, falls back to the private SkyLight call.
    /// Order taken from AeroSpace (MIT): raise first, so the window is on top when the app activates.
    static func focus(windowId: CGWindowID, pid: pid_t, tracker: WindowTracker) {
        guard let watcher = tracker.watcher(pid) else { return }
        watcher.queue.async {
            if let element = watcher.element(for: windowId) {
                AX.setBool(element, kAXMainAttribute, true)
                AX.raise(element)
            }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
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

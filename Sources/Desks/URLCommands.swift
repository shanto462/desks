import AppKit
import DesksCore
import os

/// Handles desks:// URLs. Only the fixed commands below are accepted; anything else is logged and ignored.
/// Layout numbers are 1-based like the bar (1 = first layout, 10 = tenth).
/// Optional query `?display=<UUID>`; by default the focused window's display is used.
@MainActor
enum URLCommands {
    private static let log = Logger(subsystem: "io.github.desks.app", category: "url")

    static func handle(_ url: URL, model: AppModel) {
        guard url.scheme?.lowercased() == "desks" else { return reject(url, "wrong scheme") }
        // desks://switch/3 → host "switch", path "/3".
        let command = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map(String.init)

        var display: DisplayID?
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                guard item.name == "display", let value = item.value, !value.isEmpty else {
                    return reject(url, "unknown query item")
                }
                let id = DisplayID(uuid: value)
                guard model.display(id) != nil else { return reject(url, "unknown display") }
                display = id
            }
        }

        func layoutNumber() -> Int? {
            guard parts.count == 1, let n = Int(parts[0]), (1...10).contains(n) else { return nil }
            return n - 1
        }
        func noArgs() -> Bool { parts.isEmpty }

        // Only these commands act on a display. Others reject ?display= instead of ignoring it.
        let usesDisplay: Set<String> = ["switch", "next", "previous", "new", "save-arrangement", "restore-arrangement"]
        if display != nil && !usesDisplay.contains(command) {
            return reject(url, "this command does not take a display")
        }

        switch command {
        case "switch":
            guard let id = layoutNumber() else { return reject(url, "bad layout number") }
            model.switchTo(id, on: display)
        case "next" where noArgs():
            model.engine.switchRelative(1, on: display)
            model.refresh()
        case "previous" where noArgs():
            model.engine.switchRelative(-1, on: display)
            model.refresh()
        case "new" where noArgs():
            model.createLayout(on: display)
        case "move":
            guard let id = layoutNumber() else { return reject(url, "bad layout number") }
            model.moveFocusedWindow(to: id)
        case "sticky" where noArgs():
            model.toggleSticky()
        case "overlay" where noArgs():
            model.openMoveOverlay()
        case "rescue" where noArgs():
            // Any app can open this URL and rescue changes layout membership, so ask first.
            NSApp.activate(ignoringOtherApps: true)
            confirmRescue(model)
        case "pause" where noArgs():
            model.setPaused(true)
        case "resume" where noArgs():
            model.setPaused(false)
        case "settings":
            if parts.isEmpty {
                model.openSettings(nil)
            } else if parts.count == 1, let page = SettingsPage(urlName: parts[0]) {
                model.openSettings(page)
            } else {
                return reject(url, "unknown settings page")
            }
        case "save-arrangement" where noArgs():
            model.saveCurrentArrangement(on: display)
        case "restore-arrangement" where noArgs():
            model.restoreCurrentArrangement(on: display)
        default:
            return reject(url, "unknown command")
        }
        log.info("Handled \(url.absoluteString, privacy: .public)")
    }

    private static func reject(_ url: URL, _ reason: String) {
        log.notice("Ignored \(url.absoluteString, privacy: .public): \(reason, privacy: .public)")
    }
}

extension SettingsPage {
    /// Page names for desks://settings/<page>.
    init?(urlName: String) {
        switch urlName.lowercased() {
        case "general": self = .general
        case "layouts": self = .layouts
        case "shortcuts": self = .shortcuts
        case "rules": self = .rules
        case "appearance": self = .appearance
        case "about", "permissions": self = .about
        default: return nil
        }
    }
}

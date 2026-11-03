import AppKit
import DesksCore
import KeyboardShortcuts

private let digitKeys: [KeyboardShortcuts.Key] = [
    .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine,
]
private let keypadKeys: [KeyboardShortcuts.Key] = [
    .keypad0, .keypad1, .keypad2, .keypad3, .keypad4, .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
]
private let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]
private let ctrlOptShift: NSEvent.ModifierFlags = [.control, .option, .shift]

/// Digit key for a layout id: id 0 uses 1, ..., id 8 uses 9, id 9 uses 0.
private func digitKey(forLayout id: Int) -> KeyboardShortcuts.Key { digitKeys[(id + 1) % 10] }

extension KeyboardShortcuts.Name {
    /// ⌃⌥1..9, 0: switch to the layout with that id (index = layout id) on the focused window's display.
    static let switchTo: [Self] = (0...9).map {
        Self("switchToLayout\($0)", default: .init(digitKey(forLayout: $0), modifiers: ctrlOpt))
    }
    /// ⌃⌥⇧1..9, 0: move the focused window to the layout with that id.
    static let moveTo: [Self] = (0...9).map {
        Self("moveWindowToLayout\($0)", default: .init(digitKey(forLayout: $0), modifiers: ctrlOptShift))
    }
    /// Hidden mirrors: the number pad version of each digit shortcut. Kept in sync by Hotkeys, never shown.
    static let switchToKeypad: [Self] = (0...9).map { Self("switchToLayout\($0)Keypad") }
    static let moveToKeypad: [Self] = (0...9).map { Self("moveWindowToLayout\($0)Keypad") }

    static let previousLayout = Self("previousLayout", default: .init(.leftArrow, modifiers: ctrlOpt))
    static let nextLayout = Self("nextLayout", default: .init(.rightArrow, modifiers: ctrlOpt))
    static let moveOverlay = Self("openMoveOverlay", default: .init(.m, modifiers: ctrlOpt))
    static let toggleSticky = Self("toggleSticky", default: .init(.s, modifiers: ctrlOpt))
    static let newLayout = Self("newLayout", default: .init(.n, modifiers: ctrlOpt))
    static let toggleBar = Self("toggleBar", default: .init(.b, modifiers: ctrlOpt))
    static let rescue = Self("rescueAllWindows", default: .init(.r, modifiers: ctrlOptShift))
    static let openSettings = Self("openSettings", default: .init(.comma, modifiers: ctrlOpt))
    /// No default keys.
    static let saveArrangement = Self("saveArrangement")
    static let restoreArrangement = Self("restoreArrangement")

    static var all: [Self] {
        switchTo + moveTo + [
            previousLayout, nextLayout, moveOverlay, toggleSticky,
            newLayout, toggleBar, rescue, openSettings,
            saveArrangement, restoreArrangement,
        ]
    }
}

/// A group of shortcuts shown together in Settings.
struct ShortcutGroup: Identifiable {
    let title: String
    let footer: String?
    let items: [(title: String, name: KeyboardShortcuts.Name)]
    var id: String { title }

    static let all: [ShortcutGroup] = [
        ShortcutGroup(
            title: "Switch layouts",
            footer: "Key 1 is the first layout and key 0 is the tenth. Number keys act on the display of the focused window. Number pad keys work too.",
            items: [("Previous layout", .previousLayout), ("Next layout", .nextLayout)]
                + (0...9).map { ("Switch to \(LayoutInfo.ordinalName($0))", KeyboardShortcuts.Name.switchTo[$0]) }
        ),
        ShortcutGroup(
            title: "Move windows",
            footer: nil,
            items: [("Open move window panel", .moveOverlay), ("Show in all layouts (sticky)", .toggleSticky)]
                + (0...9).map { ("Move window to \(LayoutInfo.ordinalName($0))", KeyboardShortcuts.Name.moveTo[$0]) }
        ),
        ShortcutGroup(
            title: "App",
            footer: "The Bring all windows back shortcut runs at once with no question, so it works in an emergency. The menu item and Settings ask first.",
            items: [
                ("New layout", .newLayout),
                ("Show or hide the bar", .toggleBar),
                ("Bring all windows back", .rescue),
                ("Open Settings", .openSettings),
            ]
        ),
        ShortcutGroup(
            title: "Arrangements",
            footer: "Acts on the current layout of the focused window's display. No keys are set by default.",
            items: [
                ("Save arrangement", .saveArrangement),
                ("Restore arrangement", .restoreArrangement),
            ]
        ),
    ]
}

@MainActor
enum Hotkeys {
    /// Earlier builds mapped ⌃⌥0 to the first layout. Reset the digit shortcuts once to the new 1-based keys.
    static func migrateDigitShortcuts() {
        let key = "shortcutsDigitsOneBased"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        KeyboardShortcuts.reset(KeyboardShortcuts.Name.switchTo + KeyboardShortcuts.Name.moveTo)
        UserDefaults.standard.set(true, forKey: key)
    }

    private static var defaultsObserver: NSObjectProtocol?
    private static var syncPending = false

    /// Sets each hidden number pad mirror from its main shortcut: same modifiers, keypad digit.
    /// Cleared when the main shortcut is empty, not a top-row digit, or when a main shortcut already uses it.
    static func syncKeypadMirrors() {
        typealias KS = KeyboardShortcuts
        let mains = KS.Name.switchTo + KS.Name.moveTo
        let mirrors = KS.Name.switchToKeypad + KS.Name.moveToKeypad
        let taken = Set(KS.Name.all.compactMap { KS.getShortcut(for: $0) })
        var changed = false
        for (main, mirror) in zip(mains, mirrors) {
            var wanted: KS.Shortcut?
            if let shortcut = KS.getShortcut(for: main),
               let key = shortcut.key,
               let index = digitKeys.firstIndex(of: key) {
                let candidate = KS.Shortcut(keypadKeys[index], modifiers: shortcut.modifiers)
                if !taken.contains(candidate) { wanted = candidate }
            }
            if KS.getShortcut(for: mirror) != wanted {
                KS.setShortcut(wanted, for: mirror)
                changed = true
            }
        }
        // Clearing a mirror unregisters its key combo even if a main shortcut uses the same combo.
        // Register the main shortcuts again (a no-op for ones still registered).
        if changed { KS.enable(KS.Name.all) }
    }

    /// Shortcut changes land in UserDefaults, often during a SwiftUI pass. Sync on the next turn.
    private static func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                syncPending = false
                syncKeypadMirrors()
            }
        }
    }

    static func register(model: AppModel) {
        migrateDigitShortcuts()
        syncKeypadMirrors()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { scheduleSync() }
        }
        for n in 0...9 {
            let switchTo: () -> Void = { [weak model] in model?.switchFromHotkey(n) }
            let moveTo: () -> Void = { [weak model] in model?.moveFocusedWindow(to: n) }
            KeyboardShortcuts.onKeyDown(for: .switchTo[n], action: switchTo)
            KeyboardShortcuts.onKeyDown(for: .switchToKeypad[n], action: switchTo)
            KeyboardShortcuts.onKeyDown(for: .moveTo[n], action: moveTo)
            KeyboardShortcuts.onKeyDown(for: .moveToKeypad[n], action: moveTo)
        }
        KeyboardShortcuts.onKeyDown(for: .previousLayout) { [weak model] in model?.switchRelative(-1) }
        KeyboardShortcuts.onKeyDown(for: .nextLayout) { [weak model] in model?.switchRelative(1) }
        KeyboardShortcuts.onKeyDown(for: .moveOverlay) { [weak model] in model?.openMoveOverlay() }
        KeyboardShortcuts.onKeyDown(for: .toggleSticky) { [weak model] in model?.toggleSticky() }
        KeyboardShortcuts.onKeyDown(for: .newLayout) { [weak model] in model?.createLayout(on: nil) }
        KeyboardShortcuts.onKeyDown(for: .toggleBar) { [weak model] in model?.toggleBar() }
        KeyboardShortcuts.onKeyDown(for: .rescue) { [weak model] in model?.rescue() }
        KeyboardShortcuts.onKeyDown(for: .openSettings) { [weak model] in model?.openSettings(nil) }
        KeyboardShortcuts.onKeyDown(for: .saveArrangement) { [weak model] in model?.saveCurrentArrangement() }
        KeyboardShortcuts.onKeyDown(for: .restoreArrangement) { [weak model] in model?.restoreCurrentArrangement() }
    }

    static func resetToDefaults() {
        KeyboardShortcuts.reset(KeyboardShortcuts.Name.all)
        scheduleSync()
    }
}

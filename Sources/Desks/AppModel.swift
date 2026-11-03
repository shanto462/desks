import AppKit
import Combine
import DesksCore

/// UserDefaults keys and defaults for UI preferences.
enum Prefs {
    static let showBar = "showBar"
    static let showOverFullScreen = "showOverFullScreen"
    static let menuBarIcon = "menuBarIcon"
    static let barSize = "barSize"
    static let barOpacity = "barOpacity"
    static let barLabels = "barChipStyle"
    static let parkCorner = "parkCorner"
    static let barLocked = "barLocked"
    /// [display uuid: [x, y]] relative bar position inside the visible frame.
    static let barPositions = "barPositions"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showBar: true,
            showOverFullScreen: false,
            menuBarIcon: MenuBarIcon.grid.rawValue,
            barSize: BarSize.medium.rawValue,
            barOpacity: 1.0,
            barLabels: BarLabels.icons.rawValue,
            parkCorner: EngineOptions.ParkCorner.auto.rawValue,
            barLocked: false,
        ])
    }
}

enum BarSize: String, CaseIterable, Identifiable {
    case small, medium
    var id: String { rawValue }
    var title: String { self == .small ? "Small" : "Medium" }
    var height: CGFloat { self == .small ? 24 : 30 }
    var fontSize: CGFloat { self == .small ? 11 : 12 }
    var iconSize: CGFloat { self == .small ? 14 : 18 }

    static var current: BarSize {
        BarSize(rawValue: UserDefaults.standard.string(forKey: Prefs.barSize) ?? "") ?? .medium
    }
}

/// What a bar chip shows next to its number.
enum BarLabels: String, CaseIterable, Identifiable {
    case icons, numbers
    var id: String { rawValue }
    var title: String { self == .icons ? "Number and app icons" : "Number only" }
}

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case grid, columns, windows, number
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "Grid"
        case .columns: return "Columns"
        case .windows: return "Windows"
        case .number: return "Current layout number"
        }
    }
    /// Symbol for the picker preview.
    var previewSymbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        case .windows: return "macwindow.on.rectangle"
        case .number: return "1.square"
        }
    }
}

extension EngineOptions.ParkCorner {
    var title: String {
        switch self {
        case .auto: return "Auto (best corner)"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

/// Wraps the engine for the UI. Publishes its state and fans out change events.
@MainActor
final class AppModel: ObservableObject {
    let engine: DesksEngine

    @Published private(set) var displays: [DisplayState] = []
    @Published private(set) var status: DesksStatus = .needsAccessibility
    @Published private(set) var warnings: [String] = []

    /// UI hooks set by the app delegate.
    var openSettings: (SettingsPage?) -> Void = { _ in }
    var openMoveOverlay: () -> Void = {}
    /// Opens Settings > Layouts with one layout's details shown.
    var openLayoutSettings: (DisplayID, Int) -> Void = { _, _ in }
    /// Feedback when a hotkey names a layout that does not exist (the bar shakes).
    var onMissingLayout: (DisplayID) -> Void = { _ in }

    private var listeners: [() -> Void] = []

    init(engine: DesksEngine) {
        self.engine = engine
        let raw = UserDefaults.standard.string(forKey: Prefs.parkCorner) ?? ""
        if let corner = EngineOptions.ParkCorner(rawValue: raw) {
            var options = engine.options
            options.parkCorner = corner
            engine.options = options
        }
        engine.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        refresh()
    }

    private var refreshPending = false

    /// Coalesced refresh on the next main-loop turn. Engine callbacks can arrive while SwiftUI
    /// is running an action or update, and publishing there is not safe.
    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    func addListener(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    /// Reads the engine state again and tells every listener.
    func refresh() {
        let newDisplays = engine.displays
        if newDisplays != displays { displays = newDisplays }
        if engine.status != status { status = engine.status }
        if engine.warnings != warnings { warnings = engine.warnings }
        listeners.forEach { $0() }
    }

    func display(_ id: DisplayID) -> DisplayState? {
        displays.first { $0.display == id }
    }

    /// The display of the focused window, else the first one.
    /// The display to act on, matching the engine: the focused window's display,
    /// else the display under the mouse, else the main display (the one with the menu bar).
    var focusedOrFirstDisplay: DisplayState? {
        if let id = engine.focusedDisplay(), let d = display(id) { return d }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let d = display(matching: screen) {
            return d
        }
        if let main = NSScreen.screens.first, let d = display(matching: main) { return d }
        return displays.first
    }

    /// Finds the engine display for a screen by its visible frame.
    private func display(matching screen: NSScreen) -> DisplayState? {
        displays.first { $0.visibleFrame == screen.visibleFrame }
            ?? displays.first { screen.frame.contains(CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY)) }
    }

    var parkCorner: EngineOptions.ParkCorner {
        get { engine.options.parkCorner }
        set {
            var options = engine.options
            options.parkCorner = newValue
            engine.options = options
            UserDefaults.standard.set(newValue.rawValue, forKey: Prefs.parkCorner)
            objectWillChange.send()
        }
    }

    // MARK: Actions

    func switchTo(_ id: Int, on display: DisplayID?) {
        engine.switchTo(layout: id, on: display)
        refresh()
    }

    /// ⌃⌥digit: switch, or give quick feedback when that layout does not exist on the display.
    func switchFromHotkey(_ id: Int) {
        if let d = focusedOrFirstDisplay, !d.layouts.contains(where: { $0.id == id }) {
            onMissingLayout(d.display)
            return
        }
        switchTo(id, on: nil)
    }

    func switchRelative(_ delta: Int) {
        engine.switchRelative(delta, on: nil)
        refresh()
    }

    func createLayout(on display: DisplayID?) {
        if engine.createLayout(on: display) == nil, !displays.isEmpty {
            NSSound.beep()
        }
        refresh()
    }

    func deleteLayout(_ id: Int, on display: DisplayID) {
        guard id != 0 else { return }
        engine.deleteLayout(id, on: display)
        refresh()
    }

    func renameLayout(_ id: Int, on display: DisplayID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.renameLayout(id, on: display, to: trimmed)
        refresh()
    }

    func moveFocusedWindow(to id: Int) {
        engine.moveFocusedWindow(toLayout: id)
        refresh()
    }

    func moveWindow(_ token: WindowToken, to id: Int) {
        engine.moveWindow(token, toLayout: id)
        refresh()
    }

    func setSticky(_ token: WindowToken, _ sticky: Bool) {
        engine.setSticky(token, sticky)
        refresh()
    }

    func moveAllWindows(from source: Int, to target: Int, on display: DisplayID) {
        guard source != target else { return }
        engine.moveAllWindows(fromLayout: source, toLayout: target, on: display)
        refresh()
    }

    // MARK: v1.1: rules, apps to open, arrangements

    var rules: [WindowRule] {
        get { engine.rules }
        set {
            objectWillChange.send()
            engine.rules = newValue
        }
    }

    func applyRulesNow() {
        engine.applyRulesToExistingWindows()
        refresh()
    }

    func appsToOpen(_ id: Int, on display: DisplayID) -> [String] {
        engine.appsToOpen(layout: id, on: display)
    }

    func setAppsToOpen(_ bundleIDs: [String], _ id: Int, on display: DisplayID) {
        objectWillChange.send()
        engine.setAppsToOpen(bundleIDs, layout: id, on: display)
    }

    func hasSavedArrangement(_ id: Int, on display: DisplayID) -> Bool {
        engine.hasSavedArrangement(layout: id, on: display)
    }

    func saveArrangement(_ id: Int, on display: DisplayID) {
        objectWillChange.send()
        engine.saveArrangement(layout: id, on: display)
    }

    func restoreArrangement(_ id: Int, on display: DisplayID) {
        engine.restoreArrangement(layout: id, on: display)
        refresh()
    }

    /// Save or restore the current layout of a display (the focused window's display by default).
    func saveCurrentArrangement(on display: DisplayID? = nil) {
        guard let d = display.flatMap(self.display) ?? focusedOrFirstDisplay else { return }
        saveArrangement(d.current, on: d.display)
    }

    func restoreCurrentArrangement(on display: DisplayID? = nil) {
        guard let d = display.flatMap(self.display) ?? focusedOrFirstDisplay else { return }
        restoreArrangement(d.current, on: d.display)
    }

    var restoreArrangementOnSwitch: Bool {
        get { engine.restoreArrangementOnSwitch }
        set {
            objectWillChange.send()
            engine.restoreArrangementOnSwitch = newValue
        }
    }

    func toggleSticky() {
        engine.toggleStickyFocusedWindow()
        refresh()
    }

    func rescue() {
        engine.rescueAllWindows()
        refresh()
    }

    func setPaused(_ paused: Bool) {
        if paused { engine.pause() } else { engine.resume() }
        refresh()
    }

    func toggleBar() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: Prefs.showBar), forKey: Prefs.showBar)
    }

    /// Asks for a new name in a small dialog, then renames.
    func promptRename(_ layout: LayoutInfo, on display: DisplayID) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename \"\(layout.displayName)\""
        alert.informativeText = "Leave it empty to use the default name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = layout.displayName
        field.placeholderString = "Name, for example Work"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            renameLayout(layout.id, on: display, to: field.stringValue)
        }
    }

    static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
    }
}

extension LayoutInfo {
    static let ordinals = ["First", "Second", "Third", "Fourth", "Fifth",
                           "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]

    /// Default name for a layout id: 0 is "First", 9 is "Tenth".
    static func ordinalName(_ id: Int) -> String {
        ordinals.indices.contains(id) ? ordinals[id] : "Layout"
    }

    /// The digit key for a layout: id 0 is key 1, ..., id 8 is key 9, id 9 is key 0.
    static func keyLabel(_ id: Int) -> String { "\((id + 1) % 10)" }

    /// The name to show. Falls back to the ordinal when the name is empty or just a number.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || Int(trimmed) != nil { return Self.ordinalName(id) }
        return trimmed
    }

    var keyLabel: String { Self.keyLabel(id) }

    /// Text for menus with a key hint: "1  First".
    var menuTitle: String { "\(keyLabel)  \(displayName)" }
}

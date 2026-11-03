import CoreGraphics
import Foundation

// The contract between the engine (DesksCore) and the app UI (Desks).
// The core agent implements DesksEngine. The UI agent only uses what is declared here.
// Change this file only by agreement (tell the orchestrator).

/// Stable id of a display (CGDisplay UUID string).
public struct DisplayID: Hashable, Codable, Sendable {
    public let uuid: String
    public init(uuid: String) { self.uuid = uuid }
}

/// One app with windows in a layout, for the icons in the bar.
public struct AppRef: Hashable, Sendable {
    /// Nil when the app has no bundle id.
    public let bundleID: String?
    public let pid: Int32
    /// Windows of this app in the layout (sticky windows not counted).
    public let windowCount: Int
    public init(bundleID: String?, pid: Int32, windowCount: Int) {
        self.bundleID = bundleID; self.pid = pid; self.windowCount = windowCount
    }
}

/// One layout as the UI shows it.
public struct LayoutInfo: Identifiable, Equatable, Sendable {
    /// 0...9. The first layout (id 0) always exists and cannot be deleted.
    /// Default names are ordinal words by id: "First" (0), "Second" (1), ... "Tenth" (9).
    public let id: Int
    public var name: String
    public var windowCount: Int
    /// One entry per app with windows in this layout, most recently focused first. Sticky windows are left out.
    public var apps: [AppRef]
    public init(id: Int, name: String, windowCount: Int, apps: [AppRef] = []) {
        self.id = id; self.name = name; self.windowCount = windowCount; self.apps = apps
    }
}

/// One display and its layouts.
public struct DisplayState: Equatable, Sendable {
    public let display: DisplayID
    /// Human name, e.g. "Built-in Display".
    public var name: String
    /// Visible frame in AppKit coordinates (bottom-left origin), for placing the bar.
    public var visibleFrame: CGRect
    public var layouts: [LayoutInfo]
    public var current: Int
    /// True when a native full-screen window is frontmost on this display.
    public var isFullScreenActive: Bool
    public init(display: DisplayID, name: String, visibleFrame: CGRect, layouts: [LayoutInfo],
                current: Int, isFullScreenActive: Bool) {
        self.display = display; self.name = name; self.visibleFrame = visibleFrame
        self.layouts = layouts; self.current = current; self.isFullScreenActive = isFullScreenActive
    }
}

/// Opaque handle to one managed window. The move overlay captures it before it takes key focus.
public struct WindowToken: Hashable, Sendable {
    let key: String
    init(key: String) { self.key = key }
}

/// A rule for new windows. The first enabled rule that matches wins.
public struct WindowRule: Codable, Hashable, Identifiable, Sendable {
    public enum Action: Codable, Hashable, Sendable { case layout(Int), sticky, ignore }   // layout id 0...9
    public var id: UUID
    public var enabled: Bool
    public var bundleID: String            // required, exact match
    public var titlePattern: String?       // optional regex (NSRegularExpression, case-insensitive); nil = any title
    public var action: Action
    public init(id: UUID = UUID(), enabled: Bool = true, bundleID: String, titlePattern: String? = nil, action: Action) {
        self.id = id; self.enabled = enabled; self.bundleID = bundleID
        self.titlePattern = titlePattern; self.action = action
    }
}

public enum DesksStatus: Equatable, Sendable {
    case needsAccessibility
    case running
    case paused
}

/// Options the UI can change. The engine applies them at once.
public struct EngineOptions: Equatable, Codable, Sendable {
    public enum ParkCorner: String, Codable, Sendable, CaseIterable { case auto, bottomLeft, bottomRight }
    public var parkCorner: ParkCorner = .auto
    public init() {}
}

/// Everything the UI may ask of the engine. All calls are made on the main thread.
/// A nil display means "the display of the focused window" (falling back to the main display).
public protocol DesksEngine: AnyObject {
    var status: DesksStatus { get }
    var displays: [DisplayState] { get }
    var options: EngineOptions { get set }
    /// Called on the main thread after any change to status or displays.
    var onChange: (() -> Void)? { get set }
    /// Non-fatal warnings to show in the UI (e.g. "Stage Manager is on").
    var warnings: [String] { get }

    func start()
    /// Restores every parked window and stops managing until resume().
    func pause()
    func resume()
    /// Restores every parked window. Call before the app quits.
    func shutdown()

    /// Does nothing if the layout does not exist. Leaving an empty layout that still has its
    /// default name (and no rule, apps to open or saved arrangement) removes it; higher layouts
    /// shift down by one, so ids are always 0..count-1 per display.
    func switchTo(layout id: Int, on display: DisplayID?)
    func switchRelative(_ delta: Int, on display: DisplayID?)
    /// Creates a new empty layout at the end and switches to it. Returns its id, or nil if 0...9 are all used.
    @discardableResult func createLayout(on display: DisplayID?) -> Int?
    /// Moves its windows to the first layout (id 0) and shifts higher layouts down by one.
    /// Ignored for the first layout.
    func deleteLayout(_ id: Int, on display: DisplayID)
    func renameLayout(_ id: Int, on display: DisplayID, to name: String)
    /// Moves the focused window to the layout (parks it if that layout is not current).
    func moveFocusedWindow(toLayout id: Int)
    func toggleStickyFocusedWindow()
    /// Display of the focused window, if any.
    func focusedDisplay() -> DisplayID?
    /// Brings every managed window back on screen (emergency). This also moves every window into
    /// the current layout of its display, so layout membership is lost. Windows of any app that sit
    /// in a corner are moved to the middle of their display. To show everything again without
    /// changing membership, use pause() (resume() parks them again).
    func rescueAllWindows()

    /// Token for the focused managed window, if any. Capture it before showing the overlay.
    func focusedWindowToken() -> WindowToken?
    /// Moves the window to a layout of its display (parks it if that layout is not current).
    /// Clears sticky. A missing id adds one layout at the end instead (never a gap). Ignored for unknown tokens.
    func moveWindow(_ token: WindowToken, toLayout id: Int)
    /// Sticky windows are never parked and show in every layout of their display.
    func setSticky(_ token: WindowToken, _ sticky: Bool)
    /// False for unknown tokens.
    func isSticky(_ token: WindowToken) -> Bool
    /// Moves every window of one layout to another layout on the same display.
    /// A missing target id adds one layout at the end instead.
    func moveAllWindows(fromLayout: Int, toLayout: Int, on display: DisplayID)

    // MARK: v1.1

    var rules: [WindowRule] { get set }            // first enabled match wins; applied to NEW windows; persisted in state.json
    func applyRulesToExistingWindows()             // explicit user action from Settings
    func appsToOpen(layout id: Int, on display: DisplayID) -> [String]          // bundle ids
    func setAppsToOpen(_ bundleIDs: [String], layout id: Int, on display: DisplayID)
    func saveArrangement(layout id: Int, on display: DisplayID)                 // pin current frames of that layout's windows
    func restoreArrangement(layout id: Int, on display: DisplayID)              // move them back to the pinned frames
    func hasSavedArrangement(layout id: Int, on display: DisplayID) -> Bool
    var restoreArrangementOnSwitch: Bool { get set }                          // when true, switching to a layout with a pinned arrangement restores it; persisted
}

/// Creates the real engine. Implemented in DesksCore.
public func makeEngine() -> DesksEngine { LiveEngine() }

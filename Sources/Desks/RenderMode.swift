import AppKit
import DesksCore
import SwiftUI

/// Hidden developer mode: `Desks --render-settings <dir>`.
/// Renders Settings pages, the bar and the move overlay with sample data to PNG files, then exits.
/// It never creates the real engine, never asks for Accessibility, and creates no bar panels,
/// hotkeys or menu bar item. Windows are drawn off screen and never ordered in.
@MainActor
enum RenderMode {
    static func requestedDirectory() -> URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-settings"), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into dir: URL) {
        Prefs.registerDefaults()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let full = AppModel(engine: SampleEngine(displays: SampleEngine.threeDisplays))
        let empty = AppModel(engine: SampleEngine(displays: [], status: .needsAccessibility))

        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = NSAppearance(named: name)!
            for page in SettingsPage.allCases {
                renderSettings(model: full, page: page, appearance: appearance,
                               to: dir.appendingPathComponent("settings-\(page.rawValue)-\(label).png"))
            }
            renderSettings(model: full, page: .layouts, appearance: appearance,
                           to: dir.appendingPathComponent("settings-layouts-details-\(label).png"),
                           focus: .init(display: DisplayID(uuid: "SAMPLE-A"), layout: 1))
            renderSettings(model: empty, page: .rules, appearance: appearance,
                           to: dir.appendingPathComponent("settings-rules-empty-\(label).png"))
            renderSettings(model: empty, page: .layouts, appearance: appearance,
                           to: dir.appendingPathComponent("settings-layouts-empty-\(label).png"))
            renderSettings(model: empty, page: .about, appearance: appearance,
                           to: dir.appendingPathComponent("settings-about-noaccess-\(label).png"))
            renderBar(display: SampleEngine.threeDisplays[0], appearance: appearance,
                      to: dir.appendingPathComponent("bar-\(label).png"))
            renderOverlay(display: SampleEngine.threeDisplays[0], appearance: appearance,
                          to: dir.appendingPathComponent("overlay-\(label).png"))
        }
        for (label, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            renderAnimations(appearance: NSAppearance(named: name)!, label: label, dir: dir)
        }
        print("Rendered to \(dir.path)")
    }

    // MARK: Rendering

    private static func renderSettings(model: AppModel, page: SettingsPage, appearance: NSAppearance, to url: URL,
                                       focus: SettingsNavigation.LayoutRef? = nil) {
        let navigation = SettingsNavigation()
        navigation.page = page
        navigation.focusedLayout = focus
        let window = SettingsWindowController.makeSettingsWindow(model: model, navigation: navigation)
        window.appearance = appearance
        // DESKS_RENDER_HEIGHT (points) renders a window of a fixed height, like a real window.
        // The default is tall, so a whole page fits in one image.
        let height = ProcessInfo.processInfo.environment["DESKS_RENDER_HEIGHT"].flatMap(Double.init) ?? 1000
        window.setContentSize(NSSize(width: SettingsWindowController.defaultSize.width, height: CGFloat(height)))
        settle()
        // The theme frame includes the title bar and toolbar.
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        settle()
        write(frameView, to: url)
        window.close()
    }

    private static func renderBar(display: DisplayState, appearance: NSAppearance, to url: URL) {
        var rows: [AnyView] = []
        for size in BarSize.allCases {
            for labels in BarLabels.allCases {
                rows.append(AnyView(
                    VStack(spacing: 0) {
                        BarGrip(drag: nil)
                        ChipRow(layouts: display.layouts, current: display.current, size: size,
                                labels: labels, canAdd: true, blending: .withinWindow)
                    }
                ))
            }
        }
        let view = VStack(spacing: 14) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
        .padding(24)
        .background(SampleBackdrop())
        renderView(view, appearance: appearance, to: url)
    }

    /// Captures frames of the highlight slide and of a chip appearing, to check the animations.
    private static func renderAnimations(appearance: NSAppearance, label: String, dir: URL) {
        let sample = AnimationSample(layouts: Array(SampleEngine.threeDisplays[0].layouts.prefix(2)))
        let host = NSHostingView(rootView: AnimationSampleView(sample: sample))
        host.appearance = appearance
        let size = NSSize(width: 360, height: 90)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        settle()

        func frames(_ name: String, change: () -> Void) {
            write(host, to: dir.appendingPathComponent("anim-\(name)-0start-\(label).png"))
            change()
            for (tag, delay) in [("1early", 0.06), ("2middle", 0.08), ("3end", 0.6)] {
                RunLoop.main.run(until: Date().addingTimeInterval(delay))
                host.display()
                write(host, to: dir.appendingPathComponent("anim-\(name)-\(tag)-\(label).png"))
            }
        }
        frames("slide") { sample.current = 1 }
        sample.hover = 1
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        write(host, to: dir.appendingPathComponent("anim-hoverdelete-\(label).png"))
        sample.hover = nil
        frames("appear") {
            sample.layouts.append(LayoutInfo(id: 2, name: "Third", windowCount: 1,
                                             apps: [SampleEngine.app("com.apple.Music")]))
        }
        window.close()
    }

    private static func renderOverlay(display: DisplayState, appearance: NSAppearance, to url: URL) {
        let overlay = MoveOverlayModel()
        overlay.load(display, hasWindow: true, isSticky: false)
        let view = MoveOverlayView(overlay: overlay, blending: .withinWindow, animateIn: false)
            .padding(30)
            .background(SampleBackdrop())
        renderView(view, appearance: appearance, to: url)
    }

    private static func renderView<V: View>(_ view: V, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        settle()
        write(host, to: url)
        window.close()
    }

    /// Lets SwiftUI run its update passes.
    private static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    private static func write(_ view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Soft gradient standing in for a desktop picture behind the bar and overlay.
struct SampleBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(
            colors: scheme == .dark
                ? [Color(red: 0.12, green: 0.14, blue: 0.22), Color(red: 0.25, green: 0.16, blue: 0.30)]
                : [Color(red: 0.62, green: 0.76, blue: 0.93), Color(red: 0.93, green: 0.78, blue: 0.80)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// Engine with fixed sample data. Does nothing on actions.
final class SampleEngine: DesksEngine {
    var status: DesksStatus
    var displays: [DisplayState]
    var options = EngineOptions()
    var onChange: (() -> Void)?
    var warnings: [String]

    init(displays: [DisplayState], status: DesksStatus = .running) {
        self.displays = displays
        self.status = status
        warnings = status == .running ? ["Stage Manager is on. Desks works, but the bar may cover the app strip."] : []
    }

    static func app(_ bundleID: String, _ windows: Int = 1) -> AppRef {
        AppRef(bundleID: bundleID, pid: -1, windowCount: windows)
    }

    static let threeDisplays: [DisplayState] = [
        DisplayState(
            display: DisplayID(uuid: "SAMPLE-A"), name: "Studio Display",
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            layouts: [
                LayoutInfo(id: 0, name: "First", windowCount: 3,
                           apps: [app("com.apple.Safari", 2), app("com.apple.finder")]),
                LayoutInfo(id: 1, name: "Writing", windowCount: 5,
                           apps: [app("com.apple.Notes"), app("com.apple.mail", 2), app("com.apple.Terminal"),
                                  app("com.apple.TextEdit")]),
                LayoutInfo(id: 2, name: "Third", windowCount: 0),
            ],
            current: 1, isFullScreenActive: false
        ),
        DisplayState(
            display: DisplayID(uuid: "SAMPLE-B"), name: "Built-in Retina Display",
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            layouts: [
                LayoutInfo(id: 0, name: "First", windowCount: 2,
                           apps: [app("com.apple.Music"), app("com.apple.iCal")]),
                LayoutInfo(id: 1, name: "Second", windowCount: 1, apps: [app("com.apple.Preview")]),
            ],
            current: 0, isFullScreenActive: false
        ),
        DisplayState(
            display: DisplayID(uuid: "SAMPLE-C"), name: "External Display",
            visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
            layouts: [LayoutInfo(id: 0, name: "First", windowCount: 0)],
            current: 0, isFullScreenActive: false
        ),
    ]

    func start() {}
    func pause() {}
    func resume() {}
    func shutdown() {}
    func switchTo(layout id: Int, on display: DisplayID?) {}
    func switchRelative(_ delta: Int, on display: DisplayID?) {}
    func createLayout(on display: DisplayID?) -> Int? { nil }
    func deleteLayout(_ id: Int, on display: DisplayID) {}
    func renameLayout(_ id: Int, on display: DisplayID, to name: String) {}
    func moveFocusedWindow(toLayout id: Int) {}
    func toggleStickyFocusedWindow() {}
    func focusedDisplay() -> DisplayID? { nil }
    func rescueAllWindows() {}
    func focusedWindowToken() -> WindowToken? { nil }
    func moveWindow(_ token: WindowToken, toLayout id: Int) {}
    func setSticky(_ token: WindowToken, _ sticky: Bool) {}
    func isSticky(_ token: WindowToken) -> Bool { false }
    func moveAllWindows(fromLayout: Int, toLayout: Int, on display: DisplayID) {}

    // v1.1 sample data, built-in apps only.
    var rules: [WindowRule] = [
        WindowRule(bundleID: "com.apple.mail", action: .layout(5)),
        WindowRule(bundleID: "com.apple.Safari", titlePattern: "docs|wiki", action: .layout(0)),
        WindowRule(enabled: false, bundleID: "com.apple.Music", titlePattern: "(a|aa)+", action: .sticky),
        WindowRule(bundleID: "com.apple.Terminal", titlePattern: "(unclosed", action: .ignore),
    ]
    var restoreArrangementOnSwitch = true
    private var apps: [String: [String]] = ["SAMPLE-A-1": ["com.apple.mail", "com.apple.Notes", "com.apple.Terminal"]]
    private var saved: Set<String> = ["SAMPLE-A-1", "SAMPLE-B-0"]
    func applyRulesToExistingWindows() {}
    func appsToOpen(layout id: Int, on display: DisplayID) -> [String] { apps["\(display.uuid)-\(id)"] ?? [] }
    func setAppsToOpen(_ bundleIDs: [String], layout id: Int, on display: DisplayID) { apps["\(display.uuid)-\(id)"] = bundleIDs }
    func saveArrangement(layout id: Int, on display: DisplayID) { saved.insert("\(display.uuid)-\(id)") }
    func restoreArrangement(layout id: Int, on display: DisplayID) {}
    func hasSavedArrangement(layout id: Int, on display: DisplayID) -> Bool { saved.contains("\(display.uuid)-\(id)") }
}

@MainActor
final class AnimationSample: ObservableObject {
    @Published var layouts: [LayoutInfo]
    @Published var current = 0
    @Published var hover: Int?
    init(layouts: [LayoutInfo]) { self.layouts = layouts }
}

struct AnimationSampleView: View {
    @ObservedObject var sample: AnimationSample
    var body: some View {
        ChipRow(layouts: sample.layouts, current: sample.current, size: .medium, labels: .icons,
                canAdd: true, previewHoverID: sample.hover, blending: .withinWindow)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SampleBackdrop())
    }
}

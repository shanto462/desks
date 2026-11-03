import AppKit
import DesksCore
import SwiftUI
import UniformTypeIdentifiers

/// A panel that floats above the Dock and never takes focus.
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reacts to the first click (the panel is never key), reports size changes,
/// and tracks the pointer even while Desks is not the active app.
final class BarHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

/// Motion settings shared by the bar and the overlay.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Slide for the current-layout highlight, or a plain fade with Reduce motion.
    static var slide: Animation { reduce ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82) }
    static var quick: Animation { .easeOut(duration: 0.15) }
}

/// Per-panel UI state that is not engine data.
@MainActor
final class BarUIState: ObservableObject {
    @Published var gripVisible = false
    @Published var dragging = false
}

/// Owns one pill bar per display and keeps them in sync with the engine and preferences.
@MainActor
final class BarController {
    /// Room around the pill for its shadow.
    static let shadowPad: CGFloat = 6

    private struct Entry {
        let panel: BarPanel
        let host: BarHostingView<BarView>
        let ui: BarUIState
        var visible = false
        var hoverHide: DispatchWorkItem?
        var shrink: DispatchWorkItem?
    }

    private let model: AppModel
    private var panels: [DisplayID: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Mouse and panel origin when a drag started, per display.
    private var dragStart: [DisplayID: (mouse: NSPoint, origin: NSPoint)] = [:]

    init(model: AppModel) {
        self.model = model
        model.addListener { [weak self] in self?.scheduleRefresh() }
        model.onMissingLayout = { [weak self] display in self?.shake(display) }
        let center = NotificationCenter.default
        // UserDefaults changes can be posted while SwiftUI is laying out a view (for example an
        // @AppStorage write). Measuring the bar inside that pass re-enters SwiftUI layout and
        // crashes with an exclusivity conflict, so the refresh always runs on the next main-loop turn.
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        })
        refresh()
    }

    private var refreshScheduled = false

    /// Coalesces refresh requests and runs them outside any layout pass in progress.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        let defaults = UserDefaults.standard
        let showBar = defaults.bool(forKey: Prefs.showBar)
        let overFullScreen = defaults.bool(forKey: Prefs.showOverFullScreen)
        let active = model.status == .running

        var wanted: [DisplayID: DisplayState] = [:]
        if active {
            for d in model.displays where !d.layouts.isEmpty && d.visibleFrame.width > 0 {
                wanted[d.display] = d
            }
        }

        // Displays that are gone: remove at once.
        for (id, entry) in panels where wanted[id] == nil {
            entry.panel.orderOut(nil)
            entry.panel.close()
            panels[id] = nil
        }

        for (id, state) in wanted {
            if panels[id] == nil { panels[id] = makeEntry(for: id) }
            guard let entry = panels[id] else { continue }
            var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            if overFullScreen { behavior.insert(.fullScreenAuxiliary) }
            if entry.panel.collectionBehavior != behavior { entry.panel.collectionBehavior = behavior }

            let show = showBar && !(state.isFullScreenActive && !overFullScreen)
            layout(id)
            setVisible(show, id)
        }
        // SwiftUI updates its content on the next pass, so place the panels again after that.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for id in self.panels.keys { self.layout(id) }
            }
        }
    }

    private var targetAlpha: CGFloat {
        CGFloat(min(max(UserDefaults.standard.double(forKey: Prefs.barOpacity), 0.3), 1))
    }

    /// Fades the bar in or out (full screen, show or hide bar, pause).
    private func setVisible(_ show: Bool, _ id: DisplayID) {
        guard var entry = panels[id] else { return }
        let panel = entry.panel
        if show {
            if !entry.visible {
                entry.visible = true
                panels[id] = entry
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            if panel.alphaValue != targetAlpha {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    panel.animator().alphaValue = targetAlpha
                }
            }
        } else if entry.visible {
            entry.visible = false
            panels[id] = entry
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // Only hide if it was not shown again in the meantime.
                    if self?.panels[id]?.visible == false { panel.orderOut(nil) }
                }
            })
        }
    }

    private func makeEntry(for id: DisplayID) -> Entry {
        let panel = BarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws its own soft shadow, which follows the animated width.
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.alphaValue = 0

        let ui = BarUIState()
        let actions = BarDragActions(
            changed: { [weak self] in self?.dragChanged(id) },
            ended: { [weak self] in self?.dragEnded(id) },
            reset: { BarPositions.reset(id) }
        )
        let host = BarHostingView(rootView: BarView(displayID: id, model: model, ui: ui, drag: actions))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        host.onSizeChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.layout(id) } }
        }
        host.onHoverChange = { [weak self] inside in self?.hoverChanged(inside, id) }
        return Entry(panel: panel, host: host, ui: ui)
    }

    // MARK: Feedback

    /// A short side-to-side shake when a hotkey asks for a layout that does not exist.
    /// Reduce motion: no movement.
    private func shake(_ id: DisplayID) {
        guard !Motion.reduce, let entry = panels[id], entry.visible, dragStart[id] == nil else { return }
        let panel = entry.panel
        let base = panel.frame.origin
        let offsets: [CGFloat] = [-7, 6, -4, 3, -1, 0]
        for (i, dx) in offsets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035 * Double(i + 1)) {
                panel.setFrameOrigin(NSPoint(x: base.x + dx, y: base.y))
            }
        }
    }

    // MARK: Grip visibility

    private func hoverChanged(_ inside: Bool, _ id: DisplayID) {
        guard var entry = panels[id] else { return }
        entry.hoverHide?.cancel()
        entry.hoverHide = nil
        if inside {
            withAnimation(.easeOut(duration: 0.15)) { entry.ui.gripVisible = true }
        } else {
            let ui = entry.ui
            let work = DispatchWorkItem {
                guard !ui.dragging else { return }
                withAnimation(.easeOut(duration: 0.25)) { ui.gripVisible = false }
            }
            entry.hoverHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        panels[id] = entry
    }

    // MARK: Dragging

    private func dragChanged(_ id: DisplayID) {
        guard let entry = panels[id], let state = model.display(id) else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart[id] == nil {
            dragStart[id] = (mouse, entry.panel.frame.origin)
            entry.ui.dragging = true
            entry.ui.gripVisible = true
        }
        guard let start = dragStart[id] else { return }
        let wanted = NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                             y: start.origin.y + mouse.y - start.mouse.y)
        // Clamping to its own display also snaps it back when dragged onto another display.
        let origin = BarPositions.clamp(wanted, size: entry.panel.frame.size, in: state.visibleFrame)
        entry.panel.setFrameOrigin(origin)
    }

    private func dragEnded(_ id: DisplayID) {
        guard dragStart.removeValue(forKey: id) != nil,
              let entry = panels[id], let state = model.display(id) else { return }
        entry.ui.dragging = false
        BarPositions.save(entry.panel.frame, for: id, in: state.visibleFrame)
        // Hide the grip later if the pointer already left.
        let inside = entry.panel.frame.contains(NSEvent.mouseLocation)
        if !inside { hoverChanged(false, id) }
    }

    // MARK: Placement

    /// Sizes the panel to its content and places it at its saved spot (bottom centre by default).
    /// The panel grows at once but shrinks only after SwiftUI finished animating the pill narrower,
    /// so the pill edges never get clipped. Content is centred, so the pill does not jump.
    private func layout(_ id: DisplayID) {
        guard var entry = panels[id], model.display(id) != nil else { return }
        let fitting = entry.host.fittingSize
        guard fitting.width > 0, fitting.height > 0 else { return }
        let current = entry.panel.frame.size
        let wasPlaced = entry.visible || entry.panel.isVisible
        var size = fitting
        if wasPlaced && fitting.width < current.width && current.height == fitting.height {
            size.width = current.width
            if entry.shrink == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        self?.panels[id]?.shrink = nil
                        self?.place(id, size: fitting)
                    }
                }
                entry.shrink = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        } else {
            entry.shrink?.cancel()
            entry.shrink = nil
        }
        panels[id] = entry
        place(id, size: size)
    }

    private func place(_ id: DisplayID, size: NSSize) {
        guard let entry = panels[id], let state = model.display(id) else { return }
        let size = NSSize(width: max(size.width, entry.host.fittingSize.width), height: size.height)
        let origin: NSPoint
        if dragStart[id] != nil {
            // Keep the centre while dragging.
            let f = entry.panel.frame
            origin = BarPositions.clamp(NSPoint(x: f.midX - size.width / 2, y: f.minY), size: size, in: state.visibleFrame)
        } else {
            origin = BarPositions.origin(for: id, size: size, in: state.visibleFrame)
        }
        let frame = NSRect(origin: origin, size: size)
        if entry.panel.frame != frame { entry.panel.setFrame(frame, display: true) }
        if entry.visible, entry.panel.alphaValue != targetAlpha {
            entry.panel.alphaValue = targetAlpha
        }
    }
}

// MARK: - SwiftUI content

struct BarView: View {
    let displayID: DisplayID
    @ObservedObject var model: AppModel
    @ObservedObject var ui: BarUIState
    var drag: BarDragActions? = nil
    @AppStorage(Prefs.barSize) private var sizeRaw = BarSize.medium.rawValue
    @AppStorage(Prefs.barLabels) private var labelsRaw = BarLabels.icons.rawValue
    @AppStorage(Prefs.barLocked) private var locked = false

    var body: some View {
        let size = BarSize(rawValue: sizeRaw) ?? .medium
        let labels = BarLabels(rawValue: labelsRaw) ?? .icons
        if let state = model.display(displayID) {
            VStack(spacing: 0) {
                if !locked, let drag {
                    // Space is always reserved, so the pill never moves when the grip fades.
                    BarGrip(drag: drag, visible: ui.gripVisible || ui.dragging)
                }
                ChipRow(
                    layouts: state.layouts,
                    current: state.current,
                    size: size,
                    labels: labels,
                    canAdd: state.layouts.count < 10,
                    onSelect: { model.switchTo($0, on: displayID) },
                    onAdd: { model.createLayout(on: displayID) },
                    onRename: { model.promptRename($0, on: displayID) },
                    onDelete: { model.deleteLayout($0.id, on: displayID) },
                    onMoveAll: { model.moveAllWindows(from: $0, to: $1, on: displayID) },
                    drag: locked ? nil : drag,
                    onResetPosition: drag?.reset,
                    arrangement: ArrangementActions(
                        hasSaved: { model.hasSavedArrangement($0, on: displayID) },
                        save: { model.saveArrangement($0, on: displayID) },
                        restore: { model.restoreArrangement($0, on: displayID) },
                        appsToOpen: { model.openLayoutSettings(displayID, $0) }
                    )
                )
            }
            .padding(BarController.shadowPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

/// Grabber above the pill, like a sheet grabber. Drag it to move the bar.
struct BarGrip: View {
    let drag: BarDragActions?
    var visible = true
    @State private var hovering = false
    @State private var dragging = false

    static let hitHeight: CGFloat = 14

    var body: some View {
        Capsule()
            .fill(Color(nsColor: .secondaryLabelColor))
            .frame(width: 36, height: 5)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            .opacity(visible ? 1 : 0)
            .frame(width: 44, height: Self.hitHeight)
            // Fully clear pixels let clicks fall through a borderless window, so keep a faint fill.
            .background(Color.black.opacity(0.01))
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if !dragging { (inside ? NSCursor.openHand : NSCursor.arrow).set() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { _ in
                        if !dragging {
                            dragging = true
                            NSCursor.closedHand.set()
                        }
                        drag?.changed()
                    }
                    .onEnded { _ in
                        dragging = false
                        (hovering ? NSCursor.openHand : NSCursor.arrow).set()
                        drag?.ended()
                    }
            )
            .help("Drag to move the bar")
    }
}

/// The pill: chips on a blurred capsule. Also used as a live preview in Settings.
struct ChipRow: View {
    let layouts: [LayoutInfo]
    let current: Int
    let size: BarSize
    let labels: BarLabels
    let canAdd: Bool
    var onSelect: (Int) -> Void = { _ in }
    var onAdd: () -> Void = {}
    var onRename: (LayoutInfo) -> Void = { _ in }
    var onDelete: (LayoutInfo) -> Void = { _ in }
    var onMoveAll: (_ from: Int, _ to: Int) -> Void = { _, _ in }
    /// Nil when the bar cannot be dragged (locked, or a preview).
    var drag: BarDragActions? = nil
    var onResetPosition: (() -> Void)? = nil
    /// Nil in previews.
    var arrangement: ArrangementActions? = nil
    /// Render mode: show this chip as hovered.
    var previewHoverID: Int? = nil
    @State private var hoveredID: Int?
    /// The real bar blurs the desktop; previews blur their own backdrop.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 3) {
            ForEach(layouts) { layout in
                LayoutChip(
                    layout: layout, isCurrent: layout.id == current, size: size, labels: labels,
                    firstName: layouts.first(where: { $0.id == 0 })?.displayName ?? LayoutInfo.ordinalName(0),
                    onDelete: layout.id == 0 ? nil : { onDelete(layout) },
                    previewHover: previewHoverID == layout.id,
                    onHoverChange: { inside in
                        if inside { hoveredID = layout.id } else if hoveredID == layout.id { hoveredID = nil }
                    }
                ) {
                    onSelect(layout.id)
                }
                // Anchor for the shared highlight drawn behind all chips.
                .matchedGeometryEffect(id: layout.id, in: highlight, isSource: true)
                // The hovered chip draws above its neighbours, so its delete badge is never covered.
                .zIndex(hoveredID == layout.id || previewHoverID == layout.id ? 1 : 0)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
                .contextMenu {
                    Button("Rename...") { onRename(layout) }
                    Menu("Move All Windows To") {
                        ForEach(layouts.filter { $0.id != layout.id }) { other in
                            Button(other.menuTitle) { onMoveAll(layout.id, other.id) }
                        }
                    }
                    .disabled(layout.windowCount == 0 || layouts.count < 2)
                    if let arrangement {
                        Divider()
                        Button("Save Arrangement") { arrangement.save(layout.id) }
                            .disabled(layout.windowCount == 0)
                        Button("Restore Arrangement") { arrangement.restore(layout.id) }
                            .disabled(!arrangement.hasSaved(layout.id))
                        Button("Apps to Open...") { arrangement.appsToOpen(layout.id) }
                    }
                    Divider()
                    Button("Delete") { onDelete(layout) }
                        .disabled(layout.id == 0)
                    if let onResetPosition {
                        Divider()
                        Button("Reset Bar Position", action: onResetPosition)
                    }
                }
            }
            if canAdd {
                AddChip(size: size, action: onAdd)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(3)
        .frame(height: size.height)
        .background(currentHighlight)
        .background(dragSurface)
        .background(pill)
        .animation(Motion.slide, value: current)
        .animation(Motion.reduce ? Motion.quick : .spring(response: 0.32, dampingFraction: 0.85),
                   value: layouts.map(\.id))
        .animation(Motion.quick, value: canAdd)
        .fixedSize()
    }

    /// One capsule behind the chips that follows the current chip, so it slides without covering
    /// other chips. Not used with Reduce motion.
    @ViewBuilder private var currentHighlight: some View {
        if !Motion.reduce, layouts.contains(where: { $0.id == current }) {
            Capsule()
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: current, in: highlight, properties: .frame, isSource: false)
                .allowsHitTesting(false)
        }
    }

    /// Blur, soft shadow and a two-tone hairline that reads on light and dark wallpapers.
    private var pill: some View {
        Capsule(style: .continuous)
            .fill(.clear)
            .background(VisualEffect(material: .hudWindow, blending: blending).clipShape(Capsule(style: .continuous)))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5))
            .overlay(Capsule(style: .continuous).inset(by: 0.5).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
    }

    /// The bar background: drag it to move the bar. Chips sit on top, so their clicks are untouched.
    @ViewBuilder private var dragSurface: some View {
        let surface = Capsule().fill(Color.white.opacity(0.001))
            .contextMenu {
                if let onResetPosition {
                    Button("Reset Bar Position", action: onResetPosition)
                }
            }
        if let drag {
            surface.gesture(
                // 4 pt threshold, so a click is never a drag. Screen coordinates are read by the controller.
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { _ in drag.changed() }
                    .onEnded { _ in drag.ended() }
            )
        } else {
            surface
        }
    }
}

/// Per-layout arrangement actions for the bar's right-click menu.
struct ArrangementActions {
    var hasSaved: (Int) -> Bool
    var save: (Int) -> Void
    var restore: (Int) -> Void
    var appsToOpen: (Int) -> Void
}

struct BarDragActions {
    var changed: () -> Void
    var ended: () -> Void
    var reset: () -> Void
}

/// Slight shrink while pressed.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct LayoutChip: View {
    let layout: LayoutInfo
    let isCurrent: Bool
    let size: BarSize
    let labels: BarLabels
    /// Name of the first layout, for the delete tooltip.
    var firstName = LayoutInfo.ordinalName(0)
    /// Nil for the first layout, which cannot be deleted.
    var onDelete: (() -> Void)? = nil
    var previewHover = false
    var onHoverChange: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var chipHover = false
    @State private var badgeHover = false

    /// Hover covers the chip and its badge, so moving onto the badge keeps it visible.
    private var hovering: Bool { chipHover || badgeHover || previewHover }

    private static let maxIcons = 3

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(layout.keyLabel)
                    .font(.system(size: size.fontSize, weight: .semibold).monospacedDigit())
                    .numberChange(layout.keyLabel)
                    .frame(minWidth: size.fontSize * 0.75)
                if hasIcons {
                    AppIconStrip(apps: layout.apps, max: Self.maxIcons, iconSize: size.iconSize)
                }
            }
            .padding(.horizontal, hasIcons ? 8 : 0)
            .frame(minWidth: size.height - 6, maxHeight: .infinity, alignment: .center)
            .foregroundStyle(foreground)
            .background(background)
            .contentShape(Capsule())
            .scaleEffect(hovering && !Motion.reduce ? 1.05 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { chipHover = $0; onHoverChange(hovering) }
        .help(tooltip)
        // An overlay does not change the chip's size. The badge is its own button (own hit area),
        // and it is not part of the background drag surface, so it never starts a drag.
        .overlay(alignment: .topTrailing) {
            if let onDelete, hovering {
                DeleteBadge(help: deleteHelp, action: onDelete)
                    .offset(x: 5, y: -5)
                    .onHover { badgeHover = $0; onHoverChange(hovering) }
                    .transition(Motion.reduce ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: hasIcons)
        .animation(Motion.quick, value: isCurrent)
    }

    private var deleteHelp: String {
        switch layout.windowCount {
        case 0: return "Delete layout"
        case 1: return "Delete layout, its 1 window moves to \(firstName)"
        default: return "Delete layout, its \(layout.windowCount) windows move to \(firstName)"
        }
    }

    private var tooltip: String {
        "\(layout.displayName): " + (layout.windowCount == 1 ? "1 window" : "\(layout.windowCount) windows")
    }

    private var hasIcons: Bool { labels == .icons && !layout.apps.isEmpty }
    private var isEmpty: Bool { layout.windowCount == 0 && layout.apps.isEmpty }

    private var foreground: Color {
        if isCurrent { return .white }
        return isEmpty ? Color.primary.opacity(0.4) : Color.primary.opacity(0.85)
    }

    /// Hover fill. The current-layout fill is drawn once by ChipRow behind all chips and slides;
    /// with Reduce motion each chip fills itself and the change is a fade.
    private var background: some View {
        Capsule().fill(isCurrent && Motion.reduce
                       ? Color.accentColor
                       : Color.primary.opacity(hovering && !isCurrent ? 0.12 : 0))
    }
}

extension View {
    /// Animates a number label when it changes (layouts renumber after a delete).
    @ViewBuilder func numberChange(_ value: String) -> some View {
        if #available(macOS 14, *) {
            contentTransition(.numericText()).animation(Motion.quick, value: value)
        } else {
            id(value).transition(.opacity).animation(Motion.quick, value: value)
        }
    }
}

/// Small round "x" shown on a hovered chip.
struct DeleteBadge: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.65))
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Up to `max` app icons, then an ellipsis when there are more apps. Icons cross-fade as they change.
struct AppIconStrip: View {
    let apps: [AppRef]
    let max: Int
    let iconSize: CGFloat

    private var shown: [AppRef] { Array(apps.prefix(max)) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shown, id: \.iconKey) { app in
                Image(nsImage: AppIcons.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: iconSize, height: iconSize)
                    .transition(.opacity)
            }
            if apps.count > max {
                Text("\u{2026}")
                    .font(.system(size: iconSize * 0.7, weight: .bold))
                    .baselineOffset(1)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown.map(\.iconKey))
    }
}

extension AppRef {
    /// Stable key per app for icons and animations.
    var iconKey: String { bundleID ?? "pid:\(pid)" }
}

/// Saved bar positions, per display uuid, relative to the visible frame so they survive resolution changes.
enum BarPositions {
    private static let margin: CGFloat = 2

    static func origin(for id: DisplayID, size: NSSize, in vf: CGRect) -> NSPoint {
        let saved = UserDefaults.standard.dictionary(forKey: Prefs.barPositions)?[id.uuid] as? [Double]
        let wanted: NSPoint
        if let saved, saved.count == 2 {
            wanted = NSPoint(x: vf.minX + CGFloat(saved[0]) * vf.width - size.width / 2,
                             y: vf.minY + CGFloat(saved[1]) * vf.height)
        } else {
            wanted = NSPoint(x: vf.midX - size.width / 2, y: vf.minY)
        }
        return clamp(wanted, size: size, in: vf)
    }

    static func clamp(_ point: NSPoint, size: NSSize, in vf: CGRect) -> NSPoint {
        let maxX = max(vf.minX + margin, vf.maxX - size.width - margin)
        let maxY = max(vf.minY + margin, vf.maxY - size.height - margin)
        return NSPoint(x: min(max(point.x, vf.minX + margin), maxX).rounded(),
                       y: min(max(point.y, vf.minY + margin), maxY).rounded())
    }

    /// Stores the bar's centre x and bottom y as fractions of the visible frame.
    static func save(_ frame: NSRect, for id: DisplayID, in vf: CGRect) {
        guard vf.width > 0, vf.height > 0 else { return }
        var all = UserDefaults.standard.dictionary(forKey: Prefs.barPositions) ?? [:]
        all[id.uuid] = [Double((frame.midX - vf.minX) / vf.width), Double((frame.minY - vf.minY) / vf.height)]
        UserDefaults.standard.set(all, forKey: Prefs.barPositions)
    }

    static func reset(_ id: DisplayID) {
        var all = UserDefaults.standard.dictionary(forKey: Prefs.barPositions) ?? [:]
        all[id.uuid] = nil
        UserDefaults.standard.set(all, forKey: Prefs.barPositions)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: Prefs.barPositions)
    }
}

/// App icons by pid or bundle id, cached.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: AppRef) -> NSImage {
        let key = app.iconKey
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let running = NSRunningApplication(processIdentifier: app.pid), let icon = running.icon {
            image = icon
        } else if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .application)
        }
        cache[key] = image
        return image
    }
}

struct AddChip: View {
    let size: BarSize
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: size.fontSize - 1, weight: .semibold))
                .frame(width: size.height - 6, height: size.height - 6)
                .foregroundStyle(Color.primary.opacity(hovering ? 0.9 : 0.35))
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
                .scaleEffect(hovering && !Motion.reduce ? 1.05 : 1)
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .help("New layout")
    }
}

import AppKit
import DesksCore
import SwiftUI

/// Panel that can take key focus while the move overlay is open.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class MoveOverlayModel: ObservableObject {
    enum Target: Equatable { case layout(Int), sticky }

    struct Row: Identifiable {
        let target: Target
        let key: String
        let title: String
        let detail: String
        let isCurrent: Bool
        var isOn = false
        var apps: [AppRef] = []
        var id: String { key }
    }

    @Published var displayName = ""
    /// False when no managed window had focus when the panel opened.
    @Published var hasWindow = true
    @Published var rows: [Row] = []
    @Published var selection = 0
    var onPick: (Target) -> Void = { _ in }
    var onCancel: () -> Void = {}

    func load(_ state: DisplayState?, hasWindow: Bool, isSticky: Bool) {
        displayName = state?.name ?? ""
        self.hasWindow = hasWindow
        guard hasWindow else {
            rows = []
            selection = 0
            return
        }
        var rows: [Row] = (state?.layouts ?? []).map { layout in
            Row(
                target: .layout(layout.id),
                key: layout.keyLabel,
                title: layout.displayName,
                detail: layout.windowCount == 1 ? "1 window" : "\(layout.windowCount) windows",
                isCurrent: layout.id == state?.current,
                apps: layout.apps
            )
        }
        if state != nil {
            rows.append(Row(target: .sticky, key: "S", title: "All layouts (sticky)",
                            detail: isSticky ? "On. Pick it again to turn it off." : "Stays on screen in every layout",
                            isCurrent: false, isOn: isSticky))
        }
        self.rows = rows
        selection = rows.firstIndex { !$0.isCurrent } ?? 0
    }
}

/// The ⌃⌥M panel: pick a layout for the focused window.
@MainActor
final class MoveOverlayController {
    private let model: AppModel
    private let overlay = MoveOverlayModel()
    private var panel: OverlayPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var didActivate = false
    private var resignObserver: NSObjectProtocol?
    /// The window to move, captured before the panel takes focus.
    private var token: WindowToken?

    init(model: AppModel) {
        self.model = model
        overlay.onPick = { [weak self] in self?.pick($0) }
        overlay.onCancel = { [weak self] in self?.close(restoreFocus: true) }
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isOpen { close(restoreFocus: true) } else { show() }
    }

    func show() {
        model.refresh()
        token = model.engine.focusedWindowToken()
        overlay.load(model.focusedOrFirstDisplay,
                     hasWindow: token != nil,
                     isSticky: token.map { model.engine.isSticky($0) } ?? false)
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousApp = nil }

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: MoveOverlayView(overlay: overlay))
        panel.contentView = host
        let size = host.fittingSize
        let screen = screenForOverlay()
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel.setFrame(NSRect(x: (vf.midX - size.width / 2).rounded(),
                              y: (vf.midY - size.height / 2 + vf.height * 0.1).rounded(),
                              width: size.width, height: size.height), display: true)

        // A non-activating panel can usually take key focus without stealing the active app.
        // If it cannot, activate Desks and give focus back when the panel closes.
        didActivate = false
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if !panel.isKeyWindow {
            didActivate = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
        // The content fades in, so compute the window shadow again once it is drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak panel] in panel?.invalidateShadow() }
    }

    private func screenForOverlay() -> NSScreen? {
        if let d = model.focusedOrFirstDisplay {
            let center = NSPoint(x: d.visibleFrame.midX, y: d.visibleFrame.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
        }
        return NSScreen.main
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            // Clicking elsewhere closes the panel, like Spotlight.
            MainActor.assumeIsolated {
                guard let self, self.isOpen else { return }
                self.close(restoreFocus: false)
            }
        }
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let keyCode = event.keyCode
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            let used = MainActor.assumeIsolated { self.handle(keyCode: keyCode, chars: chars) }
            return used ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the key was used.
    private func handle(keyCode: UInt16, chars: String) -> Bool {
        guard isOpen else { return false }
        let rows = overlay.rows
        switch keyCode {
        case 53: // Esc
            close(restoreFocus: true)
            return true
        case 125: // Down
            if !rows.isEmpty { overlay.selection = (overlay.selection + 1) % rows.count }
            return true
        case 126: // Up
            if !rows.isEmpty { overlay.selection = (overlay.selection - 1 + rows.count) % rows.count }
            return true
        case 36, 76: // Return, Enter
            if rows.indices.contains(overlay.selection) { pick(rows[overlay.selection].target) }
            return true
        default:
            break
        }
        // Number pad digits by key code, in case the characters are not plain digits.
        let keypadCodes: [UInt16: Int] = [82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        if let digit = keypadCodes[keyCode] ?? Int(chars), let row = rows.first(where: { $0.target == .layout((digit + 9) % 10) }) {
            pick(row.target)
            return true
        }
        if chars == "s", rows.contains(where: { $0.target == .sticky }) {
            pick(.sticky)
            return true
        }
        return true // Swallow other keys while open.
    }

    private func pick(_ target: MoveOverlayModel.Target) {
        let picked = token
        close(restoreFocus: true)
        guard let picked else { return }
        switch target {
        case .layout(let id): model.moveWindow(picked, to: id)
        case .sticky: model.setSticky(picked, !model.engine.isSticky(picked))
        }
    }

    /// Closes the panel. Returns true when focus was handed back to another app.
    @discardableResult
    private func close(restoreFocus: Bool) -> Bool {
        // Read and clear state first: orderOut can post didResignKey, which calls close again.
        let app = previousApp
        let activated = didActivate
        previousApp = nil
        didActivate = false
        token = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        guard restoreFocus, activated, let app else { return false }
        if #available(macOS 14, *) { app.activate() } else { app.activate(options: []) }
        return true
    }
}

struct MoveOverlayView: View {
    @ObservedObject var overlay: MoveOverlayModel
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// False skips the appear animation (render mode).
    var animateIn = true
    @Namespace private var selectionSpace
    @State private var appeared = false

    var body: some View {
        content
            .scaleEffect(appeared || Motion.reduce ? 1 : 0.96)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                if animateIn {
                    withAnimation(.easeOut(duration: 0.16)) { appeared = true }
                } else {
                    appeared = true
                }
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Move window to")
                    .font(.headline)
                if !overlay.displayName.isEmpty {
                    Text(overlay.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)

            if overlay.rows.isEmpty {
                Text(overlay.hasWindow
                     ? "No layouts yet. Desks needs Accessibility access to see your windows."
                     : "No window to move. Click a window first, then try again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(overlay.rows.enumerated()), id: \.element.id) { index, row in
                        if row.target == .sticky { Divider().padding(.vertical, 3) }
                        OverlayRow(row: row, selected: index == overlay.selection, space: selectionSpace)
                            .onTapGesture { overlay.onPick(row.target) }
                            .onHover { if $0 { overlay.selection = index } }
                    }
                }
                .animation(Motion.reduce ? Motion.quick : .spring(response: 0.25, dampingFraction: 0.85),
                           value: overlay.selection)
            }

            Text("Press a number, or use the arrows and Return. Esc closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
        }
        .padding(12)
        .frame(width: 340)
        .background(VisualEffect(material: .hudWindow, blending: blending))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct OverlayRow: View {
    let row: MoveOverlayModel.Row
    let selected: Bool
    let space: Namespace.ID

    var body: some View {
        HStack(spacing: 10) {
            Text(row.key)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.detail).font(.caption).opacity(0.7)
            }
            Spacer(minLength: 8)
            if !row.apps.isEmpty {
                AppIconStrip(apps: row.apps, max: 4, iconSize: 18)
            }
            if row.isCurrent {
                Text("Current").font(.caption).opacity(0.7)
            }
            if row.isOn {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background {
            if selected {
                // The highlight slides between rows as the selection moves.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: "selection", in: space)
            }
        }
        .contentShape(Rectangle())
    }
}

/// NSVisualEffectView for SwiftUI backgrounds.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

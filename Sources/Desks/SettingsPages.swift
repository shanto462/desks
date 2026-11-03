import AppKit
import DesksCore
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    @AppStorage(Prefs.showBar) private var showBar = true
    @AppStorage(Prefs.showOverFullScreen) private var showOverFullScreen = false
    @AppStorage(Prefs.menuBarIcon) private var menuBarIcon = MenuBarIcon.grid.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Desks at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Toggle("Pause Desks", isOn: Binding(
                    get: { model.status == .paused },
                    set: { model.setPaused($0) }
                ))
                .disabled(model.status == .needsAccessibility)
            } header: {
                Text("Desks")
            } footer: {
                Text("Pausing brings every window back and stops Desks until you resume.")
                    .settingsFooter()
            }

            Section {
                Toggle("Show the layout bar", isOn: $showBar)
                Toggle("Show the bar over full screen apps", isOn: $showOverFullScreen)
                    .disabled(!showBar)
            } header: {
                Text("Bar")
            } footer: {
                Text("The bar floats above windows at the bottom of each display. Drag its handle to move it.")
                    .settingsFooter()
            }

            Section {
                Picker("Hide windows in", selection: Binding(
                    get: { model.parkCorner },
                    set: { model.parkCorner = $0 }
                )) {
                    ForEach(EngineOptions.ParkCorner.allCases, id: \.self) { corner in
                        Text(corner.title).tag(corner)
                    }
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Windows of other layouts are moved to this corner of the screen. A tiny edge may stay visible.")
                    .settingsFooter()
            }

            Section {
                Picker("Menu bar icon", selection: $menuBarIcon) {
                    ForEach(MenuBarIcon.allCases) { icon in
                        Label(icon.title, systemImage: icon.previewSymbol).tag(icon.rawValue)
                    }
                }
            } header: {
                Text("Menu bar")
            }
        }
        .formStyle(.grouped)
        .withWarnings(model.warnings)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Could not change this: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Layouts

struct LayoutsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { scroll(proxy) }
                .onChange(of: navigation.focusedLayout) { _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let ref = navigation.focusedLayout else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(LayoutRow.rowID(ref.display, ref.layout), anchor: .center) }
        }
    }

    private var form: some View {
        Form {
            if model.displays.isEmpty {
                Section {
                    EmptyNote(
                        symbol: "display",
                        title: "No displays yet",
                        text: model.status == .needsAccessibility
                            ? "Give Desks Accessibility access so it can see your windows."
                            : "Desks has not found any displays yet."
                    )
                }
            } else {
                Section {
                    Text("Each display has its own layouts. Click a name to rename it. Deleting a layout moves its windows to the first layout. The first layout cannot be deleted. Empty layouts you have not renamed are removed when you leave them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: Binding(get: { model.restoreArrangementOnSwitch },
                                         set: { model.restoreArrangementOnSwitch = $0 })) {
                        Text("Restore saved arrangement when switching")
                        Text("Windows go back to their saved places each time you open a layout with a saved arrangement.")
                    }
                }
            }
            ForEach(model.displays, id: \.display) { display in
                DisplayLayoutsSection(model: model, display: display, focused: navigation.focusedLayout)
            }
        }
        .formStyle(.grouped)
    }
}

/// One display: a row per layout, then an "Add Layout" row.
private struct DisplayLayoutsSection: View {
    @ObservedObject var model: AppModel
    let display: DisplayState
    let focused: SettingsNavigation.LayoutRef?

    var body: some View {
        Section {
            ForEach(display.layouts) { layout in
                LayoutRow(
                    model: model,
                    display: display.display,
                    layout: layout,
                    isCurrent: layout.id == display.current,
                    isFocused: focused == .init(display: display.display, layout: layout.id),
                    onRename: { model.renameLayout(layout.id, on: display.display, to: $0) },
                    onSwitch: { model.switchTo(layout.id, on: display.display) },
                    onDelete: { model.deleteLayout(layout.id, on: display.display) }
                )
            }
            Button {
                model.createLayout(on: display.display)
            } label: {
                Label("Add Layout", systemImage: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(display.layouts.count >= 10)
        } header: {
            Label(display.name, systemImage: "display")
        }
    }
}

private struct LayoutRow: View {
    @ObservedObject var model: AppModel
    let display: DisplayID
    let layout: LayoutInfo
    let isCurrent: Bool
    let isFocused: Bool
    let onRename: (String) -> Void
    let onSwitch: () -> Void
    let onDelete: () -> Void
    @State private var draft = ""
    @State private var expanded = false

    static func rowID(_ display: DisplayID, _ layout: Int) -> String { "\(display.uuid)-\(layout)" }

    private var saved: Bool { model.hasSavedArrangement(layout.id, on: display) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainLine
            if expanded {
                LayoutDetails(model: model, display: display, layout: layout)
                    .padding(.top, 10)
                    .padding(.leading, 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .id(Self.rowID(display, layout.id))
        .animation(Motion.quick, value: expanded)
        .onAppear { if isFocused { expanded = true } }
        .onChange(of: isFocused) { if $0 { expanded = true } }
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            Text(layout.keyLabel)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .numberChange(layout.keyLabel)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.1)))
            TextField("", text: $draft, prompt: Text(LayoutInfo.ordinalName(layout.id)))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(commit)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            if saved {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("This layout has a saved arrangement")
            }
            AppIconStrip(apps: layout.apps, max: 3, iconSize: 18)
                .frame(width: 72, alignment: .trailing)
            Text(layout.windowCount == 1 ? "1 window" : "\(layout.windowCount) windows")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 80, alignment: .trailing)
            Group {
                if isCurrent {
                    Text("Current")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                } else {
                    Button("Show", action: onSwitch)
                        .controlSize(.small)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .frame(width: 64)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .opacity(layout.id == 0 ? 0 : 1)
            .disabled(layout.id == 0)
            .help("Delete layout")
            .accessibilityHidden(layout.id == 0)
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(expanded ? "Hide apps and arrangement" : "Apps to open and saved arrangement")
        }
        .onAppear { draft = layout.name }
        .onChange(of: layout.name) { draft = $0 }
        // onDisappear runs inside a view update: rename (which publishes model changes) a moment later.
        .onDisappear { DispatchQueue.main.async(execute: commit) }
    }

    private func commit() {
        if draft != layout.name { onRename(draft) }
    }
}

/// Apps to open and the saved arrangement for one layout.
private struct LayoutDetails: View {
    @ObservedObject var model: AppModel
    let display: DisplayID
    let layout: LayoutInfo

    private var apps: [String] { model.appsToOpen(layout.id, on: display) }
    private var saved: Bool { model.hasSavedArrangement(layout.id, on: display) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open these apps when switching")
                    Text("Desks opens them if they are not running when you switch to this layout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AppPickerMenu(title: "Add App", exclude: Set(apps)) { id in
                    model.setAppsToOpen(apps + [id], layout.id, on: display)
                }
            }
            if !apps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(apps, id: \.self) { id in
                        HStack(spacing: 6) {
                            AppIconView(bundleID: id, size: 18)
                            Text(AppInfo.name(id))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                            Button {
                                model.setAppsToOpen(apps.filter { $0 != id }, layout.id, on: display)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: saved ? "pin.fill" : "pin")
                    .foregroundStyle(saved ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Window arrangement")
                    Text(saved ? "Saved. Restore puts the windows back in their saved places."
                               : "Save the size and place of this layout's windows to restore them later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Save Arrangement") { model.saveArrangement(layout.id, on: display) }
                    .disabled(layout.windowCount == 0)
                Button("Restore") { model.restoreArrangement(layout.id, on: display) }
                    .disabled(!saved)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Shortcuts

/// Finds Desks actions that share the same shortcut.
@MainActor
final class ShortcutConflicts: ObservableObject {
    @Published private(set) var others: [String: [KeyboardShortcuts.Name]] = [:]
    private var observer: NSObjectProtocol?
    private var pending = false

    static let titles: [String: String] = Dictionary(
        ShortcutGroup.all.flatMap { $0.items }.map { ($0.name.rawValue, $0.title) },
        uniquingKeysWith: { first, _ in first }
    )

    init() {
        recompute()
        // KeyboardShortcuts stores shortcuts in UserDefaults, so any change shows up here.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRecompute() }
        }
    }

    /// Defaults can change inside a SwiftUI update pass, so publish on the next main-loop turn.
    private func scheduleRecompute() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.recompute()
            }
        }
    }

    func recompute() {
        var byShortcut: [KeyboardShortcuts.Shortcut: [KeyboardShortcuts.Name]] = [:]
        for name in KeyboardShortcuts.Name.all {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
                byShortcut[shortcut, default: []].append(name)
            }
        }
        var result: [String: [KeyboardShortcuts.Name]] = [:]
        for names in byShortcut.values where names.count > 1 {
            for name in names {
                result[name.rawValue] = names.filter { $0 != name }
            }
        }
        if result != others { others = result }
    }

    func title(_ name: KeyboardShortcuts.Name) -> String {
        Self.titles[name.rawValue] ?? name.rawValue
    }
}

struct ShortcutsPage: View {
    @StateObject private var conflicts = ShortcutConflicts()

    var body: some View {
        Form {
            ForEach(ShortcutGroup.all) { group in
                Section {
                    ForEach(group.items, id: \.name.rawValue) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            KeyboardShortcuts.Recorder(item.title, name: item.name)
                                .help(item.name == .rescue
                                      ? "Runs at once with no question, for emergencies. The menu and Settings ask first."
                                      : "")
                            ForEach(conflicts.others[item.name.rawValue] ?? [], id: \.rawValue) { other in
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                    Text("Same shortcut as \"\(conflicts.title(other))\". Only one of them will work.")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Clear the Other") {
                                        KeyboardShortcuts.setShortcut(nil, for: other)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let footer = group.footer {
                        Text(footer).settingsFooter()
                    }
                }
            }
            Section {
                HStack {
                    Text("Desks warns you when a shortcut is already used by macOS, another menu, or another Desks action.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") { Hotkeys.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearancePage: View {
    @AppStorage(Prefs.barSize) private var sizeRaw = BarSize.medium.rawValue
    @AppStorage(Prefs.barOpacity) private var opacity = 1.0
    @AppStorage(Prefs.barLabels) private var labelsRaw = BarLabels.icons.rawValue
    @AppStorage(Prefs.barLocked) private var locked = false

    private static func app(_ id: String) -> AppRef { AppRef(bundleID: id, pid: -1, windowCount: 1) }

    /// Preview data with built-in apps only.
    private let sample = [
        LayoutInfo(id: 0, name: "First", windowCount: 2, apps: [app("com.apple.Safari"), app("com.apple.finder")]),
        LayoutInfo(id: 1, name: "Second", windowCount: 4,
                   apps: [app("com.apple.Notes"), app("com.apple.mail"), app("com.apple.Terminal"), app("com.apple.TextEdit")]),
        LayoutInfo(id: 2, name: "Third", windowCount: 1, apps: [app("com.apple.Music")]),
        LayoutInfo(id: 3, name: "Fourth", windowCount: 0),
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    ChipRow(
                        layouts: sample,
                        current: 1,
                        size: BarSize(rawValue: sizeRaw) ?? .medium,
                        labels: BarLabels(rawValue: labelsRaw) ?? .icons,
                        canAdd: true,
                        blending: .withinWindow
                    )
                    .opacity(min(max(opacity, 0.3), 1))
                    .allowsHitTesting(false)
                    Spacer()
                }
                .padding(.vertical, 26)
                .background(SampleBackdrop().clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
            } header: {
                Text("Preview")
            }

            Section {
                Picker("Bar size", selection: $sizeRaw) {
                    ForEach(BarSize.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Labels", selection: $labelsRaw) {
                    ForEach(BarLabels.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $opacity, in: 0.3...1)
                        Text("\(Int((opacity * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } header: {
                Text("Bar")
            }

            Section {
                Toggle("Lock bar position", isOn: $locked)
                LabeledContent("Put every bar back at the bottom centre") {
                    Button("Reset Bar Position") { BarPositions.resetAll() }
                }
            } header: {
                Text("Position")
            } footer: {
                Text("Drag the handle on top of the bar to move it. Each display keeps its own spot.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Permissions & About

struct AboutPage: View {
    @ObservedObject var model: AppModel

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    let granted = model.status != .needsAccessibility
                    Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(granted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text(granted ? "Access is on." : "Desks needs this to move and hide windows.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Privacy & Security") { model.openAccessibilitySettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("If Desks is in the list but still not working, remove it, add it again, then quit and reopen Desks.")
                    .settingsFooter()
            }


            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bring all windows back")
                        Text("Emergency only. Moves every window into the current layout, so your layouts lose their windows. To just see everything for a while, use Pause instead.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Bring Back...") { confirmRescue(model) }
                        .disabled(model.status == .needsAccessibility)
                }
            } header: {
                Text("Help")
            }

            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Desks").font(.title3.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Free layouts for every display.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("About")
            }

            Section {
                CreditRow(name: "KeyboardShortcuts", note: "Shortcut recorder. MIT License.",
                          url: "https://github.com/sindresorhus/KeyboardShortcuts")
                CreditRow(name: "AeroSpace", note: "Ideas for hiding windows. MIT License.",
                          url: "https://github.com/nikitabobko/AeroSpace")
            } header: {
                Text("Credits")
            }
        }
        .formStyle(.grouped)
        .withWarnings(model.warnings)
    }
}

private struct CreditRow: View {
    let name: String
    let note: String
    let url: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let link = URL(string: url) {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(url)
            }
        }
    }
}

// MARK: - Shared bits

/// Asks before the rescue, because it changes layout membership.
@MainActor
func confirmRescue(_ model: AppModel) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Bring all windows back?"
    alert.informativeText = "Every window moves into the current layout of its display. Your other layouts will be empty. To see all windows without changing layouts, use Pause Desks instead."
    alert.addButton(withTitle: "Bring All Back")
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: "Pause Instead")
    switch alert.runModal() {
    case .alertFirstButtonReturn: model.rescue()
    case .alertThirdButtonReturn: model.setPaused(true)
    default: break
    }
}

/// Yellow box that lists engine warnings.
struct WarningBanner: View {
    let warnings: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(warnings, id: \.self) { warning in
                    Text(warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1)
        )
    }
}

extension View {
    /// Shows engine warnings in a yellow banner above the page content.
    func withWarnings(_ warnings: [String]) -> some View {
        VStack(spacing: 0) {
            if !warnings.isEmpty {
                WarningBanner(warnings: warnings)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            self
        }
    }
}

struct EmptyNote: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

extension Text {
    /// Section footer text, leading aligned like System Settings.
    func settingsFooter() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
    }
}

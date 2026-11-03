import AppKit
import DesksCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apps

/// Name and icon for a bundle id.
@MainActor
enum AppInfo {
    private static var names: [String: String] = [:]

    static func name(_ bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        var name = bundleID
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let local = running.localizedName {
            name = local
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        }
        names[bundleID] = name
        return name
    }

    static func icon(_ bundleID: String) -> NSImage {
        AppIcons.icon(for: AppRef(bundleID: bundleID, pid: -1, windowCount: 0))
    }

    /// Apps with a Dock icon that are running now, sorted by name. Desks itself is left out.
    static func runningApps() -> [String] {
        let own = Bundle.main.bundleIdentifier
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != own }
        return Array(Set(ids)).sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// Lets the user pick an app in /Applications. Returns its bundle id.
    static func chooseApp() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// Small app icon.
struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 20

    var body: some View {
        Image(nsImage: AppInfo.icon(bundleID))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// "Add" menu: running apps, then "Choose App...".
struct AppPickerMenu: View {
    let title: String
    var exclude: Set<String> = []
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let apps = AppInfo.runningApps().filter { !exclude.contains($0) }
            if apps.isEmpty {
                Text("No other apps are open")
            } else {
                Section("Open Apps") {
                    ForEach(apps, id: \.self) { id in
                        Button {
                            onPick(id)
                        } label: {
                            Label { Text(AppInfo.name(id)) } icon: { Image(nsImage: AppInfo.icon(id)) }
                        }
                    }
                }
            }
            Divider()
            Button("Choose App...") {
                // Let the menu close before the open panel runs.
                DispatchQueue.main.async {
                    if let id = AppInfo.chooseApp() { onPick(id) }
                }
            }
        } label: {
            Label(title, systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Rules

extension WindowRule.Action {
    /// Picker tag: "layout-0" ... "layout-9", "sticky", "ignore".
    var tag: String {
        switch self {
        case .layout(let id): return "layout-\(id)"
        case .sticky: return "sticky"
        case .ignore: return "ignore"
        }
    }

    init?(tag: String) {
        switch tag {
        case "sticky": self = .sticky
        case "ignore": self = .ignore
        default:
            guard tag.hasPrefix("layout-"), let id = Int(tag.dropFirst(7)), (0...9).contains(id) else { return nil }
            self = .layout(id)
        }
    }
}

struct RulesPage: View {
    @ObservedObject var model: AppModel
    @State private var applied = false

    var body: some View {
        Form {
            Section {
                if model.rules.isEmpty {
                    EmptyNote(
                        symbol: "list.bullet.rectangle",
                        title: "No rules yet",
                        text: "Add a rule to send an app's new windows to a layout, show them in all layouts, or let Desks ignore them."
                    )
                } else {
                    // A grouped Form on macOS does not reliably support drag to reorder (.onMove),
                    // so rows have up and down buttons instead.
                    ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                        RuleRow(
                            rule: rule,
                            layoutCount: layoutCount,
                            canMoveUp: index > 0,
                            canMoveDown: index < model.rules.count - 1,
                            onChange: { updated in update(updated) },
                            onDelete: { model.rules.removeAll { $0.id == rule.id } },
                            onMove: { move(rule, by: $0) }
                        )
                    }
                }
                HStack {
                    AppPickerMenu(title: "Add Rule") { bundleID in
                        // Starts off, so a half-made rule never catches windows. The user turns it on.
                        model.rules.append(WindowRule(enabled: false, bundleID: bundleID, action: .layout(0)))
                    }
                    Spacer()
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Rules act on new windows. The first matching rule wins, so use the arrows to change the order. New rules start off: set them up, then turn them on. Title patterns are regular expressions and ignore case. Press Return to save a pattern. Leave it empty to match every window of the app.")
                    .settingsFooter()
            }

            Section {
                LabeledContent {
                    Button(applied ? "Done" : "Apply Now") {
                        model.applyRulesNow()
                        applied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { applied = false }
                    }
                    .disabled(model.rules.isEmpty || model.status != .running)
                } label: {
                    Text("Apply rules to open windows")
                    Text("Moves windows that are open now, as if they were new.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Layouts on the focused window's display (or the first display). Rules list these.
    private var layoutCount: Int { max(1, model.focusedOrFirstDisplay?.layouts.count ?? 1) }

    private func update(_ rule: WindowRule) {
        guard let i = model.rules.firstIndex(where: { $0.id == rule.id }), model.rules[i] != rule else { return }
        model.rules[i] = rule
    }

    private func move(_ rule: WindowRule, by delta: Int) {
        guard let i = model.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let j = i + delta
        guard model.rules.indices.contains(j) else { return }
        model.rules.swapAt(i, j)
    }
}

private struct RuleRow: View {
    let rule: WindowRule
    let layoutCount: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: (WindowRule) -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    @State private var pattern = ""
    @FocusState private var patternFocused: Bool

    /// The pattern as it would be saved.
    private var normalized: String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var unsaved: Bool { normalized != rule.titlePattern }

    private var patternError: String? {
        // Same check the engine uses, so the row warns about exactly the patterns that get skipped.
        RulePattern.problem(pattern.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { var r = rule; r.enabled = $0; onChange(r) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                AppIconView(bundleID: rule.bundleID, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppInfo.name(rule.bundleID))
                        .lineLimit(1)
                    Text(rule.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { rule.action.tag },
                    set: { if let a = WindowRule.Action(tag: $0) { var r = rule; r.action = a; onChange(r) } }
                )) {
                    ForEach(0..<min(layoutCount, 10), id: \.self) { id in
                        Text("Layout \(id + 1)").tag("layout-\(id)")
                    }
                    if layoutCount < 10 {
                        // Stores the next id; the engine creates that layout at the end when needed.
                        Text("New layout at the end").tag("layout-\(layoutCount)")
                    }
                    if case .layout(let id) = rule.action, id > layoutCount {
                        Text("Layout \(id + 1) (not created yet)").tag("layout-\(id)")
                    }
                    Divider()
                    Text("Sticky (all layouts)").tag("sticky")
                    Text("Ignore").tag("ignore")
                }
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 2) {
                    Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                        .disabled(!canMoveUp)
                        .help("Move up")
                    Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                        .disabled(!canMoveDown)
                        .help("Move down")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete rule")
            }
            HStack(spacing: 8) {
                Text("Title")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)
                TextField("", text: $pattern, prompt: Text("Any title"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($patternFocused)
                    .onSubmit(commit)
                if patternError == nil && unsaved {
                    Text("Not saved yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, 52)
            if let patternError {
                // Own line, so long reasons wrap instead of squeezing the field.
                Label(patternError, systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 94)
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.enabled ? 1 : 0.65)
        .contextMenu {
            Button("Move Up") { onMove(-1) }
            Button("Move Down") { onMove(1) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onAppear { pattern = rule.titlePattern ?? "" }
        // Saved on Return or when the field loses focus, never per keystroke.
        .onChange(of: patternFocused) { focused in
            if !focused { DispatchQueue.main.async(execute: commit) }
        }
        .onDisappear { DispatchQueue.main.async(execute: commit) }
    }

    private func commit() {
        guard patternError == nil, unsaved else { return }
        var r = rule
        r.titlePattern = normalized
        onChange(r)
    }
}

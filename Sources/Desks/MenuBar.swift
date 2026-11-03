import AppKit
import DesksCore
import KeyboardShortcuts

/// The menu bar item and its menu. The menu is rebuilt each time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var defaultsObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.toolTip = "Desks"
        model.addListener { [weak self] in self?.updateIcon() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        let raw = UserDefaults.standard.string(forKey: Prefs.menuBarIcon) ?? ""
        let choice = MenuBarIcon(rawValue: raw) ?? .grid
        let symbol: String
        switch model.status {
        case .needsAccessibility:
            symbol = "exclamationmark.triangle"
        case .paused:
            symbol = "pause.rectangle"
        case .running:
            if choice == .number, let d = model.focusedOrFirstDisplay {
                symbol = "\(LayoutInfo.keyLabel(d.current)).square"
            } else {
                symbol = choice == .number ? MenuBarIcon.grid.previewSymbol : choice.previewSymbol
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Desks")
        image?.isTemplate = true
        if statusItem.button?.image?.name() != symbol {
            image?.setName(symbol)
            statusItem.button?.image = image
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refresh()
        menu.removeAllItems()

        addStatusSection(to: menu)

        let displays = model.displays
        if !displays.isEmpty {
            menu.addItem(.separator())
            for display in displays {
                if displays.count > 1 {
                    menu.addItem(header(display.name))
                }
                for layout in display.layouts {
                    let item = action(layout.menuTitle) { [weak self] in
                        self?.model.switchTo(layout.id, on: display.display)
                    }
                    item.state = layout.id == display.current ? .on : .off
                    // The engine ignores switches while paused or without Accessibility.
                    item.isEnabled = model.status == .running
                    if displays.count > 1 { item.indentationLevel = 1 }
                    menu.addItem(item)
                }
            }
        }

        let running = model.status == .running
        menu.addItem(.separator())
        menu.addItem(action("New Layout", symbol: "plus.rectangle", shortcut: .newLayout, enabled: running) { [weak self] in
            self?.model.createLayout(on: nil)
        })
        menu.addItem(action("Move Window to...", symbol: "arrow.right.square", shortcut: .moveOverlay, enabled: running) { [weak self] in
            self?.model.openMoveOverlay()
        })
        menu.addItem(action("Show Window in All Layouts", symbol: "pin", shortcut: .toggleSticky, enabled: running) { [weak self] in
            self?.model.toggleSticky()
        })
        let barItem = action("Show Bar", shortcut: .toggleBar) { [weak self] in self?.model.toggleBar() }
        barItem.state = UserDefaults.standard.bool(forKey: Prefs.showBar) ? .on : .off
        menu.addItem(barItem)

        menu.addItem(.separator())
        let rescue = action("Bring All Windows Back...", symbol: "arrow.uturn.backward.square", shortcut: .rescue,
                            enabled: model.status != .needsAccessibility) { [weak self] in
            guard let self else { return }
            // Same question as Settings, because rescue changes layout membership.
            NSApp.activate(ignoringOtherApps: true)
            confirmRescue(self.model)
        }
        rescue.toolTip = "Emergency only. Moves every window into the current layout, so layouts lose their windows. Use Pause Desks to see everything without changing layouts."
        menu.addItem(rescue)
        switch model.status {
        case .paused:
            menu.addItem(action("Resume Desks", symbol: "play") { [weak self] in self?.model.setPaused(false) })
        case .running:
            menu.addItem(action("Pause Desks", symbol: "pause") { [weak self] in self?.model.setPaused(true) })
        case .needsAccessibility:
            break
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings...", symbol: "gearshape", shortcut: .openSettings) { [weak self] in
            self?.model.openSettings(nil)
        })
        let quit = action("Quit Desks") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        menu.addItem(quit)
    }

    private func addStatusSection(to menu: NSMenu) {
        switch model.status {
        case .running:
            menu.addItem(info("Desks is on", symbol: "checkmark.circle"))
        case .paused:
            menu.addItem(info("Desks is paused", symbol: "pause.circle"))
        case .needsAccessibility:
            menu.addItem(info("Desks needs Accessibility access", symbol: "exclamationmark.triangle"))
            menu.addItem(action("Open Accessibility Settings...", symbol: "lock.shield") { [weak self] in
                self?.model.openAccessibilitySettings()
            })
        }
        for warning in model.warnings {
            // Enabled so it reads clearly; a click opens Settings where the warning is shown too.
            let item = action(warning) { [weak self] in self?.model.openSettings(.general) }
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
                .withSymbolConfiguration(config)
            item.toolTip = "Open Settings"
            menu.addItem(item)
        }
    }

    // MARK: Item helpers

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func info(_ title: String, symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = false
        return item
    }

    private func action(
        _ title: String,
        symbol: String? = nil,
        shortcut: KeyboardShortcuts.Name? = nil,
        enabled: Bool = true,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let shortcut { item.setShortcut(KeyboardShortcuts.Shortcut(name: shortcut)) }
        item.isEnabled = enabled
        return item
    }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

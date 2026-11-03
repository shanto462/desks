import AppKit
import DesksCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var bar: BarController!
    private var menuBar: MenuBarController!
    private var overlay: MoveOverlayController!
    private var settings: SettingsWindowController!
    private var signalSources: [DispatchSourceSignal] = []
    private var didShutDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        NSApp.mainMenu = Self.makeMainMenu()

        let engine = makeEngine()
        model = AppModel(engine: engine)
        settings = SettingsWindowController(model: model)
        overlay = MoveOverlayController(model: model)
        model.openSettings = { [weak self] page in self?.settings.show(page: page) }
        model.openMoveOverlay = { [weak self] in self?.overlay.toggle() }
        model.openLayoutSettings = { [weak self] display, id in self?.settings.showLayout(id, on: display) }

        menuBar = MenuBarController(model: model)
        bar = BarController(model: model)
        Hotkeys.register(model: model)
        installSignalHandlers()

        engine.start()
        model.refresh()

        if model.status == .needsAccessibility {
            settings.show(page: .about)
        }
    }

    /// desks:// URLs (from the CLI or other apps).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls { URLCommands.handle(url, model: model) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutDownEngine()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    /// Restores parked windows once, whatever the reason for quitting.
    private func shutDownEngine() {
        guard !didShutDown, let model else { return }
        didShutDown = true
        model.engine.shutdown()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.shutDownEngine() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// A small main menu so Cmd-Q, Cmd-W and copy and paste work while Settings is open.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Desks")
        appMenu.addItem(withTitle: "Settings...", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Desks", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Desks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        return main
    }

    @objc private func showSettings() {
        settings.show()
    }
}

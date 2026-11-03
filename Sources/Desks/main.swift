import AppKit

let app = NSApplication.shared

if let dir = MainActor.assumeIsolated({ RenderMode.requestedDirectory() }) {
    // Developer render mode: no engine, no permissions, no bar, hotkeys or menu bar item.
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { RenderMode.run(into: dir) }
        exit(0)
    }
    app.run()
} else {
    // Desks is an accessory app: no Dock icon, only the menu bar item and the bars.
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

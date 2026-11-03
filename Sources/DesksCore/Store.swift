import Foundation

/// One parked window, written to disk before it is parked, so the next launch can bring it back.
struct JournalEntry: Codable, Equatable {
    var pid: Int32
    var bundleId: String
    var windowId: UInt32
    var title: String
    var homeFrame: StoredFrame
}

/// Files in ~/Library/Application Support/Desks/:
/// - state.json: displays, layouts and window fingerprints. Saved off the main thread, debounced.
/// - journal.json: parked windows. Written at once, on the calling thread, before any park.
final class Store {
    let directory: URL
    private var stateURL: URL { directory.appendingPathComponent("state.json") }
    private var journalURL: URL { directory.appendingPathComponent("journal.json") }
    private let io = DispatchQueue(label: "desks.store", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var lastJournal: [JournalEntry]?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("Desks", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: State

    /// Set when state.json could not be read. Holds the name the bad file was moved to.
    private(set) var badStateFile: String?
    private var stateWritesBlocked = false

    /// Reads state.json. A file that cannot be decoded is moved aside (never overwritten),
    /// so the user's layouts can still be recovered by hand.
    func loadState() -> ModelState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        if let state = try? JSONDecoder().decode(ModelState.self, from: data) { return state }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "state.json.bad-\(formatter.string(from: Date()))"
        let target = directory.appendingPathComponent(name)
        if (try? FileManager.default.moveItem(at: stateURL, to: target)) != nil {
            badStateFile = name
        } else {
            // Could not move it: never overwrite it.
            badStateFile = "state.json"
            stateWritesBlocked = true
        }
        return nil
    }

    /// Saves about one second after the last change. Call on the main thread.
    func scheduleSave(_ make: @escaping () -> ModelState) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = Self.encode(make())
            self.io.async { self.write(data, to: self.stateURL) }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Saves now and waits. Used on quit.
    func saveNow(_ state: ModelState) {
        pendingSave?.cancel()
        pendingSave = nil
        let data = Self.encode(state)
        io.sync { write(data, to: stateURL) }
    }

    // MARK: Journal

    func loadJournal() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        return (try? JSONDecoder().decode([JournalEntry].self, from: data)) ?? []
    }

    /// Writes the journal synchronously (atomic). Skips the write when nothing changed.
    func writeJournal(_ entries: [JournalEntry]) {
        let sorted = entries.sorted { ($0.pid, $0.windowId) < ($1.pid, $1.windowId) }
        if sorted == lastJournal { return }
        lastJournal = sorted
        if sorted.isEmpty {
            try? FileManager.default.removeItem(at: journalURL)
            return
        }
        write(Self.encode(sorted), to: journalURL)
    }

    // MARK: Helpers

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data, !(stateWritesBlocked && url == stateURL) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

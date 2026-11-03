import CoreGraphics
import Foundation

// Pure data: displays, layouts, window membership, sticky flags and MRU lists.
// No AX calls here. Lives on the main thread.

/// A frame stored as [x, y, width, height] in AX coordinates.
struct StoredFrame: Codable, Equatable {
    var x: Double, y: Double, width: Double, height: Double

    init(_ rect: CGRect) {
        x = Double(rect.minX); y = Double(rect.minY); width = Double(rect.width); height = Double(rect.height)
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self); y = try c.decode(Double.self)
        width = try c.decode(Double.self); height = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x); try c.encode(y); try c.encode(width); try c.encode(height)
    }
}

struct LayoutRecord: Codable, Equatable {
    var id: Int
    var name: String
    /// Most recently focused windows first (window keys).
    var mru: [String]
    /// Bundle ids to launch when the user switches to this layout (v1.1, optional in old files).
    var appsToOpen: [String]?
    /// Pinned frames by window key (v1.1, optional in old files).
    var arrangement: [String: StoredFrame]?
}

struct DisplayRecord: Codable, Equatable {
    var label: String
    var current: Int
    var layouts: [LayoutRecord]
}

struct WindowRecord: Codable, Equatable {
    /// Our own id for the window. Survives relaunch through fingerprint matching.
    var key: String
    var bundleId: String
    var title: String
    var role: String
    /// Order of the window among its app's standard windows.
    var index: Int
    /// Home display (UUID).
    var display: String
    var layout: Int
    var sticky: Bool
    /// Where the window sits when it is shown on its home display.
    var homeFrame: StoredFrame
    /// CGWindowID in this session. Changes after the app relaunches.
    var windowId: UInt32
    var pid: Int32
    /// Set while the home display is unplugged: the main display's layout the window joined.
    var orphanLayout: Int?
    /// Frame on the main display while orphaned.
    var orphanFrame: StoredFrame?
    /// True while the window has only been seen in native full screen: `homeFrame` is a placeholder
    /// until it leaves full screen. Optional, so old files still load.
    var homeUnknown: Bool?
}

struct ModelState: Codable {
    var version: Int = 1
    var displays: [String: DisplayRecord] = [:]
    var windows: [WindowRecord] = []
    /// v1.1 fields. Optional, so older state files still load.
    var rules: [WindowRule]?
    var restoreArrangementOnSwitch: Bool?
}

final class LayoutModel {
    static let maxLayoutId = 9
    static let mruLimit = 30

    private(set) var displays: [String: DisplayRecord] = [:]
    /// Live, matched windows by key.
    private(set) var windows: [String: WindowRecord] = [:]
    private var keyByWindowId: [UInt32: String] = [:]
    /// Rules for new windows, in order. First enabled match wins.
    var rules: [WindowRule] = []
    var restoreArrangementOnSwitch = false

    static let ordinals = ["First", "Second", "Third", "Fourth", "Fifth",
                           "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"]

    /// Default name of a layout: the ordinal word of its id ("First" for id 0).
    static func defaultName(_ id: Int) -> String {
        ordinals.indices.contains(id) ? ordinals[id] : "Layout \(id + 1)"
    }

    /// Names from older versions ("Main", or only digits) become the ordinal. User names stay.
    static func migratedName(_ name: String, id: Int) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Main" || trimmed.allSatisfy(\.isNumber) { return defaultName(id) }
        return name
    }

    // MARK: Load and save

    /// Loads displays only. Saved windows are returned for matching against live ones.
    func load(_ state: ModelState) -> [WindowRecord] {
        rules = state.rules ?? []
        restoreArrangementOnSwitch = state.restoreArrangementOnSwitch ?? false
        displays = state.displays
        for (uuid, var display) in displays {
            if !display.layouts.contains(where: { $0.id == 0 }) {
                display.layouts.append(LayoutRecord(id: 0, name: Self.defaultName(0), mru: []))
            }
            display.layouts.sort { $0.id < $1.id }
            for i in display.layouts.indices {
                display.layouts[i].mru = []
                display.layouts[i].name = Self.migratedName(display.layouts[i].name, id: display.layouts[i].id)
            }
            if !display.layouts.contains(where: { $0.id == display.current }) { display.current = 0 }
            displays[uuid] = display
        }
        var saved = state.windows
        compactOnLoad(&saved)
        return saved
    }

    /// Migration: drops empty default-named layouts (never the first or the current one) and
    /// renumbers the rest to 0..count-1 per display, so old files with gaps load compact.
    private func compactOnLoad(_ saved: inout [WindowRecord]) {
        var mappings: [String: [Int: Int]] = [:]
        for (uuid, var display) in displays {
            let used = Set(saved.filter { $0.display == uuid && !$0.sticky }.map(\.layout))
            display.layouts.removeAll { layout in
                layout.id != 0 && layout.id != display.current && !used.contains(layout.id)
                    && isDefaultAndUnused(layout)
            }
            var map: [Int: Int] = [:]
            for (index, layout) in display.layouts.enumerated() { map[layout.id] = index }
            for i in display.layouts.indices {
                let old = display.layouts[i].id
                let new = i
                if display.layouts[i].name == Self.defaultName(old) { display.layouts[i].name = Self.defaultName(new) }
                display.layouts[i].id = new
            }
            display.current = map[display.current] ?? 0
            displays[uuid] = display
            mappings[uuid] = map
        }
        for i in saved.indices {
            guard let map = mappings[saved[i].display] else { continue }
            saved[i].layout = map[saved[i].layout] ?? 0
        }
        // Rule targets are fixed numbers and never change here.
    }

    /// Default name, nothing pinned or launched, and no enabled rule points at it.
    func isDefaultAndUnused(_ layout: LayoutRecord) -> Bool {
        layout.name == Self.defaultName(layout.id)
            && (layout.appsToOpen ?? []).isEmpty
            && (layout.arrangement ?? [:]).isEmpty
            && !rules.contains { $0.enabled && $0.action == .layout(layout.id) }
    }

    func layoutRecord(_ id: Int, on uuid: String) -> LayoutRecord? {
        displays[uuid]?.layouts.first { $0.id == id }
    }

    func layoutCount(on uuid: String) -> Int { displays[uuid]?.layouts.count ?? 1 }

    /// A layout id shifted after layout `removed` was taken out: the removed one maps to the first layout.
    static func shifted(_ n: Int, removing removed: Int) -> Int {
        n == removed ? 0 : (n > removed ? n - 1 : n)
    }

    func snapshot(pendingSaved: [WindowRecord]) -> ModelState {
        var all = Array(windows.values)
        let liveKeys = Set(windows.keys)
        all.append(contentsOf: pendingSaved.filter { !liveKeys.contains($0.key) })
        all.sort { $0.key < $1.key }
        return ModelState(version: 1, displays: displays, windows: all,
                          rules: rules, restoreArrangementOnSwitch: restoreArrangementOnSwitch)
    }

    // MARK: Displays and layouts

    func ensureDisplay(_ uuid: String, label: String) {
        if var existing = displays[uuid] {
            if existing.label != label { existing.label = label; displays[uuid] = existing }
            return
        }
        displays[uuid] = DisplayRecord(label: label, current: 0,
                                       layouts: [LayoutRecord(id: 0, name: Self.defaultName(0), mru: [])])
    }

    func current(on uuid: String) -> Int { displays[uuid]?.current ?? 0 }

    func hasLayout(_ id: Int, on uuid: String) -> Bool {
        displays[uuid]?.layouts.contains { $0.id == id } ?? false
    }

    func layoutIds(on uuid: String) -> [Int] {
        displays[uuid]?.layouts.map(\.id) ?? [0]
    }

    func setCurrent(_ id: Int, on uuid: String) {
        guard var display = displays[uuid], display.layouts.contains(where: { $0.id == id }) else { return }
        display.current = id
        displays[uuid] = display
    }

    /// Adds one layout at the end (ids stay 0..count-1). Returns its id, or nil when all 10 exist.
    @discardableResult
    func appendLayout(on uuid: String) -> Int? {
        guard var display = displays[uuid], display.layouts.count <= Self.maxLayoutId else { return nil }
        let id = display.layouts.count
        display.layouts.append(LayoutRecord(id: id, name: Self.defaultName(id), mru: []))
        displays[uuid] = display
        return id
    }

    /// Removes the layout and shifts every higher layout down by one, so ids stay 0..count-1.
    /// Its windows go to the first layout. Default names follow the new position; custom names stay.
    /// Rule targets are fixed numbers and are not changed (a rule for a missing number adds one
    /// layout at the end when it fires).
    /// Returns false for the first layout or a missing one.
    @discardableResult
    func removeLayout(_ id: Int, on uuid: String, mainUUID: String?) -> Bool {
        guard id != 0, var display = displays[uuid], let index = display.layouts.firstIndex(where: { $0.id == id }) else { return false }
        let movedMRU = display.layouts[index].mru
        display.layouts.remove(at: index)
        if let zero = display.layouts.firstIndex(where: { $0.id == 0 }) {
            display.layouts[zero].mru.append(contentsOf: movedMRU.filter { !display.layouts[zero].mru.contains($0) })
        }
        for i in display.layouts.indices where display.layouts[i].id > id {
            let old = display.layouts[i].id
            if display.layouts[i].name == Self.defaultName(old) { display.layouts[i].name = Self.defaultName(old - 1) }
            display.layouts[i].id = old - 1
        }
        display.current = Self.shifted(display.current, removing: id)
        displays[uuid] = display
        for (key, var window) in windows {
            var changed = false
            if window.display == uuid {
                window.layout = Self.shifted(window.layout, removing: id)
                changed = true
            }
            if uuid == mainUUID, let orphan = window.orphanLayout {
                window.orphanLayout = Self.shifted(orphan, removing: id)
                changed = true
            }
            if changed { windows[key] = window }
        }
        return true
    }

    func renameLayout(_ id: Int, on uuid: String, to name: String) {
        guard var display = displays[uuid], let index = display.layouts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty or digits-only names fall back to the ordinal: the bar never shows a bare number.
        let allowed = trimmed.isEmpty || trimmed.allSatisfy(\.isNumber) ? Self.defaultName(id) : String(trimmed.prefix(40))
        display.layouts[index].name = allowed
        displays[uuid] = display
    }

    func layouts(on uuid: String) -> [LayoutRecord] { displays[uuid]?.layouts ?? [] }

    private func changeLayout(_ id: Int, on uuid: String, _ change: (inout LayoutRecord) -> Void) {
        guard var display = displays[uuid], let index = display.layouts.firstIndex(where: { $0.id == id }) else { return }
        change(&display.layouts[index])
        displays[uuid] = display
    }

    private func layout(_ id: Int, on uuid: String) -> LayoutRecord? {
        displays[uuid]?.layouts.first { $0.id == id }
    }

    func appsToOpen(_ id: Int, on uuid: String) -> [String] { layout(id, on: uuid)?.appsToOpen ?? [] }

    func setAppsToOpen(_ bundleIds: [String], _ id: Int, on uuid: String) {
        var seen = Set<String>()
        let clean = bundleIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        changeLayout(id, on: uuid) { $0.appsToOpen = clean.isEmpty ? nil : clean }
    }

    func arrangement(_ id: Int, on uuid: String) -> [String: StoredFrame] { layout(id, on: uuid)?.arrangement ?? [:] }

    func setArrangement(_ frames: [String: StoredFrame], _ id: Int, on uuid: String) {
        changeLayout(id, on: uuid) { $0.arrangement = frames.isEmpty ? nil : frames }
    }

    func mru(_ id: Int, on uuid: String) -> [String] {
        displays[uuid]?.layouts.first { $0.id == id }?.mru ?? []
    }

    // MARK: Windows

    func record(_ key: String) -> WindowRecord? { windows[key] }

    func key(forWindowId id: UInt32) -> String? { keyByWindowId[id] }

    func record(forWindowId id: UInt32) -> WindowRecord? {
        keyByWindowId[id].flatMap { windows[$0] }
    }

    var allRecords: [WindowRecord] { Array(windows.values) }

    func upsert(_ record: WindowRecord) {
        if let old = windows[record.key], old.windowId != record.windowId {
            keyByWindowId[old.windowId] = nil
        }
        windows[record.key] = record
        keyByWindowId[record.windowId] = record.key
    }

    func update(_ key: String, _ change: (inout WindowRecord) -> Void) {
        guard var record = windows[key] else { return }
        change(&record)
        windows[key] = record
    }

    func remove(_ key: String) {
        guard let record = windows.removeValue(forKey: key) else { return }
        if keyByWindowId[record.windowId] == key { keyByWindowId[record.windowId] = nil }
        for (uuid, var display) in displays {
            var changed = false
            for i in display.layouts.indices where display.layouts[i].mru.contains(key) {
                display.layouts[i].mru.removeAll { $0 == key }
                changed = true
            }
            if changed { displays[uuid] = display }
        }
    }

    /// The display and layout a window is shown in right now.
    /// Orphans (home display unplugged) count as members of the main display.
    func placement(of record: WindowRecord, connected: Set<String>, mainUUID: String?) -> (display: String, layout: Int) {
        if connected.contains(record.display) || mainUUID == nil {
            return (record.display, record.layout)
        }
        let main = mainUUID!
        return (main, record.orphanLayout ?? current(on: main))
    }

    func isVisible(_ record: WindowRecord, connected: Set<String>, mainUUID: String?) -> Bool {
        if record.sticky { return true }
        let p = placement(of: record, connected: connected, mainUUID: mainUUID)
        return p.layout == current(on: p.display)
    }

    /// Puts the window first in the MRU list of the layout it is shown in.
    func touchMRU(_ key: String, connected: Set<String>, mainUUID: String?) {
        guard let record = windows[key], !record.sticky else { return }
        let p = placement(of: record, connected: connected, mainUUID: mainUUID)
        guard var display = displays[p.display], let index = display.layouts.firstIndex(where: { $0.id == p.layout }) else { return }
        var list = display.layouts[index].mru
        if list.first == key { return }
        list.removeAll { $0 == key }
        list.insert(key, at: 0)
        if list.count > Self.mruLimit { list.removeLast(list.count - Self.mruLimit) }
        display.layouts[index].mru = list
        displays[p.display] = display
    }

    /// Apps with windows in the layout, most recently focused first (by the layout's MRU list),
    /// then the rest by bundle id. Sticky windows are left out.
    func apps(_ id: Int, on uuid: String, connected: Set<String>, mainUUID: String?) -> [AppRef] {
        var members: [String: WindowRecord] = [:]
        for record in windows.values where !record.sticky {
            let p = placement(of: record, connected: connected, mainUUID: mainUUID)
            if p.display == uuid, p.layout == id { members[record.key] = record }
        }
        guard !members.isEmpty else { return [] }
        var counts: [Int32: Int] = [:]
        var bundles: [Int32: String] = [:]
        for record in members.values {
            counts[record.pid, default: 0] += 1
            bundles[record.pid] = record.bundleId
        }
        var order: [Int32] = []
        for key in mru(id, on: uuid) {
            if let pid = members[key]?.pid, !order.contains(pid) { order.append(pid) }
        }
        let rest = counts.keys.filter { !order.contains($0) }
            .sorted { (bundles[$0] ?? "", $0) < (bundles[$1] ?? "", $1) }
        order.append(contentsOf: rest)
        return order.map { pid in
            // WindowTracker uses "pid.<n>" for apps without a bundle id.
            let bundle = bundles[pid].flatMap { $0.hasPrefix("pid.") ? nil : $0 }
            return AppRef(bundleID: bundle, pid: pid, windowCount: counts[pid] ?? 0)
        }
    }

    func windowCount(_ id: Int, on uuid: String, connected: Set<String>, mainUUID: String?) -> Int {
        windows.values.reduce(0) { sum, record in
            guard !record.sticky else { return sum }
            let p = placement(of: record, connected: connected, mainUUID: mainUUID)
            return sum + (p.display == uuid && p.layout == id ? 1 : 0)
        }
    }
}

import AppKit
import CoreGraphics

/// One connected display. Frames are in AX coordinates (top-left origin of the main display, y down)
/// unless the name says AppKit.
struct ScreenInfo: Equatable {
    let id: DisplayID
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let visibleFrameAppKit: CGRect
    let isMain: Bool
}

enum HideCorner: Equatable { case bottomLeft, bottomRight }

enum Screens {
    /// Reads the connected displays. Main display first, then left to right.
    static func current() -> [ScreenInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        let mainID = CGMainDisplayID()
        var result: [ScreenInfo] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let cgID = CGDirectDisplayID(number.uint32Value)
            result.append(ScreenInfo(
                id: DisplayID(uuid: uuid(of: cgID)),
                name: screen.localizedName,
                frame: toAX(screen.frame, primaryHeight: primaryHeight),
                visibleFrame: toAX(screen.visibleFrame, primaryHeight: primaryHeight),
                visibleFrameAppKit: screen.visibleFrame,
                isMain: cgID == mainID))
        }
        return result.sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            return a.frame.minX < b.frame.minX
        }
    }

    /// UUID string that survives reboots. Falls back to the numeric id.
    static func uuid(of cgID: CGDirectDisplayID) -> String {
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, cfUUID) as String? {
            return string
        }
        return "display-\(cgID)"
    }

    static func toAX(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The display that holds the centre of the frame, else the closest one.
    static func screen(for frame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) { return hit }
        return screens.min { distance(center, $0.frame) < distance(center, $1.frame) }
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// True when only a thin line of the window is on any display: it is parked (by us or a crash).
    static func looksParked(_ frame: CGRect, in screens: [ScreenInfo]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        for screen in screens {
            let part = frame.intersection(screen.frame)
            if !part.isNull, part.width > 8, part.height > 8 { return false }
        }
        return true
    }

    /// Makes a frame usable: if most of it is on some display, keep it. Otherwise centre it on `target`.
    static func sanitize(_ frame: CGRect, target: ScreenInfo, screens: [ScreenInfo]) -> CGRect {
        let area = frame.width * frame.height
        if area > 0 {
            for screen in screens {
                let part = frame.intersection(screen.frame)
                if !part.isNull, part.width * part.height >= area * 0.5 { return frame }
            }
        }
        let box = target.visibleFrame
        let width = min(max(frame.width, 200), box.width)
        let height = min(max(frame.height, 150), box.height)
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    /// Keeps the frame if its centre is on `target`, else moves it to the middle of `target`.
    static func fit(_ frame: CGRect, into target: ScreenInfo) -> CGRect {
        if target.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) { return frame }
        let box = target.visibleFrame
        let width = min(max(frame.width, 200), box.width)
        let height = min(max(frame.height, 150), box.height)
        return CGRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    // MARK: Park corners

    /// Picks the bottom corner of each display that touches the fewest other displays.
    /// Adapted from AeroSpace `layout/refresh.swift` (MIT, Nikita Bobko).
    /// Returns the corner per display and the displays where both corners touch a neighbour.
    static func parkCorners(_ screens: [ScreenInfo], option: EngineOptions.ParkCorner)
        -> (corners: [DisplayID: HideCorner], blocked: [ScreenInfo])
    {
        var corners: [DisplayID: HideCorner] = [:]
        var blocked: [ScreenInfo] = []
        for screen in screens {
            let r = screen.frame
            let xOff = r.width * 0.1
            let yOff = r.height * 0.1
            let right = [CGPoint(x: r.maxX + 2, y: r.maxY - yOff),
                         CGPoint(x: r.maxX - xOff, y: r.maxY + 2),
                         CGPoint(x: r.maxX + 2, y: r.maxY + 2)]
            let left = [CGPoint(x: r.minX - 2, y: r.maxY - yOff),
                        CGPoint(x: r.minX + xOff, y: r.maxY + 2),
                        CGPoint(x: r.minX - 2, y: r.maxY + 2)]
            func score(_ points: [CGPoint]) -> Int {
                screens.reduce(0) { sum, other in
                    sum + (other.frame.contains(points[0]) ? 1 : 0)
                        + (other.frame.contains(points[1]) ? 1 : 0)
                        + (other.frame.contains(points[2]) ? 10 : 0)
                }
            }
            let leftScore = score(left)
            let rightScore = score(right)
            switch option {
            case .bottomLeft: corners[screen.id] = .bottomLeft
            case .bottomRight: corners[screen.id] = .bottomRight
            case .auto: corners[screen.id] = leftScore < rightScore ? .bottomLeft : .bottomRight
            }
            let chosen = corners[screen.id] == .bottomLeft ? leftScore : rightScore
            if chosen > 0 { blocked.append(screen) }
        }
        return (corners, blocked)
    }

    /// Top-left point that leaves about 1 px of the window on the display.
    /// Zoom jumps back with a 1 px offset, so it gets none (AeroSpace issue 527).
    static func parkPoint(on screen: ScreenInfo, corner: HideCorner, windowSize: CGSize, bundleId: String) -> CGPoint {
        let zoom = bundleId == "us.zoom.xos"
        let v = screen.visibleFrame
        switch corner {
        case .bottomRight:
            let offset: CGFloat = zoom ? 0 : 1
            return CGPoint(x: v.maxX - offset, y: v.maxY - offset)
        case .bottomLeft:
            let dx: CGFloat = zoom ? 0 : 1
            let dy: CGFloat = zoom ? 0 : 1
            return CGPoint(x: v.minX + dx - windowSize.width, y: v.maxY - dy)
        }
    }
}

import AppKit
import ApplicationServices

// Small helpers around the Accessibility (AX) C API.
// All functions here do IPC with another app, so call them on that app's serial queue,
// never on the main thread (except the cheap trust check).

enum AX {
    /// Messaging timeout for every element we talk to. A slow app then blocks only its own queue.
    static let messagingTimeout: Float = 0.5

    static let enhancedUserInterface = "AXEnhancedUserInterface"
    static let fullScreen = "AXFullScreen"

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Returns nil when the read itself failed (so callers can tell "no windows" from "app did not answer").
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let array = unsafeBitCast(value, to: CFArray.self)
        var result: [AXUIElement] = []
        for i in 0..<CFArrayGetCount(array) {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if CFGetTypeID(item) == AXUIElementGetTypeID() {
                result.append(unsafeBitCast(item, to: AXUIElement.self))
            }
        }
        return result
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = axValue(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = axValue(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = position(element), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    static func setBool(_ element: AXUIElement, _ attribute: String, _ flag: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, (flag ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef) == .success
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    static func setTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
    }

    /// Runs `body` with AXEnhancedUserInterface switched off on the app, and switches it back on after.
    /// Apps with it on (often because of VoiceOver-like tools) animate and lag when moved.
    /// Idea from AeroSpace (MIT), which credits yabai and Rectangle.
    @discardableResult
    static func withEnhancedUIOff<T>(_ app: AXUIElement, _ body: () -> T) -> T {
        let wasOn = bool(app, enhancedUserInterface) == true
        if wasOn { setBool(app, enhancedUserInterface, false) }
        defer { if wasOn { setBool(app, enhancedUserInterface, true) } }
        return body()
    }

    /// CGWindowID of a window element, through the private `_AXUIElementGetWindow`.
    static func windowId(_ element: AXUIElement) -> CGWindowID? {
        guard let fn = PrivateAPI.getWindow else { return nil }
        var id: CGWindowID = 0
        guard fn(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    /// True when Desks has Accessibility permission. Never prompts.
    static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt. The engine calls this at most once per launch.
    static func promptForTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Private functions, loaded at run time with dlsym so a missing symbol never crashes Desks.
/// Each one has a public fallback in the caller.
enum PrivateAPI {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError

    static let getWindow: GetWindowFn? = load(
        "_AXUIElementGetWindow",
        from: ["/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
               "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"])

    static let getProcessForPID: GetProcessForPIDFn? = load(
        "GetProcessForPID",
        from: ["/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
               "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"])

    static let setFrontProcess: SetFrontProcessFn? = load(
        "_SLPSSetFrontProcessWithOptions",
        from: ["/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"])

    /// Brings the app to the front with one of its windows. Fallback when activate() is refused.
    @discardableResult
    static func bringToFront(pid: pid_t, windowId: CGWindowID) -> Bool {
        guard let getPSN = getProcessForPID, let setFront = setFrontProcess else { return false }
        var psn = ProcessSerialNumber()
        guard getPSN(pid, &psn) == noErr else { return false }
        // 0x200 = kCPSUserGenerated, the mode yabai uses.
        return setFront(&psn, windowId, 0x200) == .success
    }

    private static func load<T>(_ symbol: String, from paths: [String]) -> T? {
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, symbol) else { continue }
            return unsafeBitCast(pointer, to: T.self)
        }
        return nil
    }
}

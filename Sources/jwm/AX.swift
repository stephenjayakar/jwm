import AppKit
import ApplicationServices

/// Private but stable API used by every macOS window manager to map an AX window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ connection: Int32) -> UInt64

/// ID of the macOS Space (desktop) currently shown. Private API, as used by yabai/AeroSpace.
func activeSpace() -> UInt64 { CGSGetActiveSpace(CGSMainConnectionID()) }

@_silgen_name("CGSManagedDisplayGetCurrentSpace")
private func CGSManagedDisplayGetCurrentSpace(_ connection: Int32, _ display: CFString) -> UInt64

/// ID of the Space shown on one display (each display has its own Spaces by default).
func currentSpace(display uuid: String) -> UInt64 {
    CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), uuid as CFString)
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// nil means the app didn't answer (as opposed to having no elements).
    func elements(_ attribute: String) -> [AXUIElement]? { value(attribute) as? [AXUIElement] }

    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }

    /// Frame in AX coordinates (origin at top-left of the primary screen).
    var frame: CGRect? {
        guard let p = value(kAXPositionAttribute), let s = value(kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        if let v = AXValueCreate(.cgPoint, &point) { set(kAXPositionAttribute, v) }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let v = AXValueCreate(.cgSize, &size) { set(kAXSizeAttribute, v) }
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func perform(_ action: String) { AXUIElementPerformAction(self, action as CFString) }
}

/// AppKit uses bottom-left origin coordinates, AX uses top-left; the conversion is its own inverse.
func flipped(_ rect: CGRect) -> CGRect {
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
}

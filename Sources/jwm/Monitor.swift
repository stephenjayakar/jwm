import AppKit

/// One display. Each display has its own tabs, like an Emacs frame has its own window configurations.
final class Monitor {
    /// Display UUID: stable across reconnects, unlike CGDirectDisplayID.
    let uuid: String
    var tabs = [Tab()]
    var tabIndex = 0
    /// The Space this display showed when jwm started managing it. jwm leaves other Spaces alone.
    var homeSpace: UInt64
    /// Full frame and visible frame (no menu bar or Dock), in AX coordinates.
    var frame = CGRect.zero
    var visible = CGRect.zero

    init(uuid: String) {
        self.uuid = uuid
        homeSpace = currentSpace(display: uuid)
    }

    var tab: Tab { tabs[tabIndex] }
    var atHome: Bool { currentSpace(display: uuid) == homeSpace }
    var screen: NSScreen? { NSScreen.screens.first { displayUUID($0) == uuid } }
}

func displayUUID(_ screen: NSScreen) -> String {
    let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
    return CFUUIDCreateString(nil, uuid) as String
}

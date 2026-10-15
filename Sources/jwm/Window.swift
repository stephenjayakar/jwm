import AppKit

/// A buffer: one top-level app window.
final class Window {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let app: AXUIElement
    let appName: String
    /// True while parked offscreen by us.
    var parked = false
    /// Where we parked it; parked again when the park corner moves (displays rearranged).
    var parkedAt: CGPoint?
    /// Where the current layout puts this window; nil while parked.
    var expected: CGRect?
    /// Last time we pushed the window back, and how many times in a row; used to stop fighting
    /// apps that insist on their own frame.
    var lastCorrection = Date.distantPast
    var corrections = 0
    /// Move/resize events before this time are echoes of our own setFrame/park.
    var ownChangeUntil = Date.distantPast
    /// Smallest size the app accepted, learned when it refuses a smaller one.
    var minSize = CGSize.zero
    /// Frame before jwm touched it, restored on quit.
    var home: CGRect?

    init(id: CGWindowID, element: AXUIElement, pid: pid_t, app: AXUIElement, appName: String) {
        self.id = id
        self.element = element
        self.pid = pid
        self.app = app
        self.appName = appName
    }

    var title: String { element.string(kAXTitleAttribute) ?? "" }
    var label: String { title.isEmpty || title == appName ? appName : "\(appName) — \(title)" }

    /// Title without the " - AppName …" suffix most apps append (Chrome, Obsidian, Discord, …).
    var shortTitle: String {
        var title = self.title
        for separator in [" - ", " — ", " – "] {
            if let range = title.range(of: separator + appName) { title = String(title[..<range.lowerBound]) }
        }
        return title.isEmpty ? appName : title
    }

    var icon: NSImage? { NSRunningApplication(processIdentifier: pid)?.icon }

    static func isManageable(_ element: AXUIElement) -> Bool {
        element.string(kAXSubroleAttribute) == kAXStandardWindowSubrole
            && element.bool(kAXMinimizedAttribute) != true
            && element.bool("AXFullScreen") != true
            && element.isSettable(kAXSizeAttribute)
    }

    /// The parts of isManageable() that can change after a window was first seen.
    static func isStillManageable(_ element: AXUIElement) -> Bool {
        element.bool(kAXMinimizedAttribute) != true && element.bool("AXFullScreen") != true
    }

    func setFrame(_ rect: CGRect) {
        // Chrome/Electron animate frame changes while enhanced UI is on, which breaks resizing.
        let enhanced = app.bool("AXEnhancedUserInterface") == true
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        // Position, size, position: the size can be clamped by the old position near screen edges.
        element.setPosition(rect.origin)
        element.setSize(rect.size)
        element.setPosition(rect.origin)
        if enhanced { app.set("AXEnhancedUserInterface", kCFBooleanTrue) }
        expected = rect
        parked = false
        ownChangeUntil = Date().addingTimeInterval(0.4)
    }

    /// Moves the window's top-left corner to `point` (WM.parkPoint picks a display corner with no
    /// other display beyond it, so only a 1px sliver stays on screen).
    func park(at point: CGPoint) {
        element.setPosition(point)
        parkedAt = point
        parked = true
        expected = nil
        ownChangeUntil = Date().addingTimeInterval(0.4)
    }

    /// Activates the app first, then makes this window its key window. In the other order,
    /// activating the app brings back the app's previous key window (with two kitty windows, the
    /// wrong one ends up focused).
    func focus() {
        app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        app.set(kAXFocusedWindowAttribute, element)
        element.set(kAXMainAttribute, kCFBooleanTrue)
        element.perform(kAXRaiseAction)
    }

    func close() {
        element.element(kAXCloseButtonAttribute)?.perform(kAXPressAction)
    }
}

/// Watches one app for window creation / focus changes.
final class AppWatcher {
    let pid: pid_t
    let element: AXUIElement
    let name: String
    private let observer: AXObserver

    init?(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        element = AXUIElementCreateApplication(pid)
        name = app.localizedName ?? "?"
        AXUIElementSetMessagingTimeout(element, 0.5)

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return nil }
        self.observer = observer
        // Fails while the app is still launching; we retry on the next refresh.
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, nil) == .success
        else { return nil }
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func watch(_ window: AXUIElement) {
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowMiniaturizedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, nil)
        AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, nil)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}

private func axCallback(_: AXObserver, _ element: AXUIElement, _ notification: CFString, _: UnsafeMutableRawPointer?) {
    WM.shared.axEvent(notification as String, element)
}

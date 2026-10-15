import AppKit
import Carbon.HIToolbox

/// Global key handling via a session event tap: ⌘D starts a prefix sequence, ⌥(⇧)Tab cycles panes.
/// (⌥Tab rather than ⌃Tab, which browsers and editors use to switch their own tabs.)
final class Hotkeys {
    static let shared = Hotkeys()

    /// Tags events we post ourselves so the tap lets them through.
    private static let syntheticMarker: Int64 = 0x6A776D // "jwm"

    private var tap: CFMachPort?
    private var prefixActive = false
    /// Key-ups whose key-downs we swallowed.
    private var swallowedUps = Set<Int>()

    /// Apps that get C-v / M-v unchanged, because the program inside already uses them
    /// (Emacs and terminal apps, where jemacs, shells and readline see the keys).
    private static let scrollPassthrough: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "org.alacritty",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "org.gnu.Emacs",
        "org.gnu.AquamacsEmacs", "com.vmware.fusion",
    ]
    /// Bundle ID of the frontmost app. Written on main, read on the tap thread.
    private var frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    private let frontmostLock = NSLock()

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in Hotkeys.shared.handle(type, event) },
            userInfo: nil
        ) else { return false }
        self.tap = tap
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.frontmostLock.lock()
            self.frontmostBundleID = app?.bundleIdentifier
            self.frontmostLock.unlock()
        }
        // The tap gets its own thread: if it ran on the main thread, slow AX calls there could delay
        // it past the system's timeout, which disables the tap and lets keys through to apps.
        // All state in handle() is only touched on this thread; real work is sent to main.
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "jwm.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log("event tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == Hotkeys.syntheticMarker { return pass }

        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedUps.remove(key) != nil ? nil : pass
        }
        guard type == .keyDown else { return pass }

        let flags = event.flags
        let cmd = flags.contains(.maskCommand), ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate), shift = flags.contains(.maskShift)

        // Work happens async so the tap returns fast (slow taps get disabled by the system).
        if prefixActive {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            prefixActive = false
            swallowedUps.insert(key)
            DispatchQueue.main.async {
                Hud.shared.hide()
                WM.shared.command(key, shift: shift)
            }
            return nil
        }
        if key == kVK_ANSI_D && cmd && !ctrl && !opt && !shift {
            prefixActive = true
            swallowedUps.insert(key)
            DispatchQueue.main.async { Hud.shared.show("⌘D –") }
            return nil
        }
        // Emacs scrolling: C-v pages down, M-v (Option-V) pages up.
        if key == kVK_ANSI_V && ctrl != opt && !cmd && !shift && scrollRemapApplies() {
            swallowedUps.insert(key)
            post(ctrl ? kVK_PageDown : kVK_PageUp)
            return nil
        }
        if key == kVK_Tab && opt && !cmd && !ctrl {
            swallowedUps.insert(key)
            DispatchQueue.main.async { WM.shared.focusPane(shift ? -1 : 1) }
            return nil
        }
        return pass
    }

    private func scrollRemapApplies() -> Bool {
        frontmostLock.lock()
        defer { frontmostLock.unlock() }
        guard let id = frontmostBundleID else { return true }
        return !Hotkeys.scrollPassthrough.contains(id)
    }

    /// Posts a key press with no modifiers. A private event source keeps the physically held
    /// Control/Option out of the event.
    private func post(_ keyCode: Int) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            else { continue }
            event.flags = .maskSecondaryFn   // real Page Up/Down keys carry the fn flag
            event.setIntegerValueField(.eventSourceUserData, value: Hotkeys.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// ⌘D ⌘D sends a real ⌘D to the focused app.
    func sendLiteralPrefix() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_D), keyDown: down)
            else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Hotkeys.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

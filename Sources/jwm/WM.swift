import AppKit
import Carbon.HIToolbox

final class WM {
    static let shared = WM()

    let gap: CGFloat = 8

    private(set) var windows: [CGWindowID: Window] = [:]
    private var apps: [pid_t: AppWatcher] = [:]
    /// One entry per display, in screen order. Each display has its own tabs.
    private(set) var monitors: [Monitor] = []
    /// The display with the selected pane; commands act on it.
    private(set) var monitorIndex = 0
    /// Displays that disconnected, by UUID, so a display that drops out for a moment (sleep, KVM)
    /// gets its layout back when it reconnects.
    private var detached: [String: Monitor] = [:]
    /// While displays are being added or removed, macOS moves windows around. Their move events are
    /// not user moves, so frame checks wait until this time.
    private var displaysSettleUntil = Date.distantPast
    /// The window jwm last focused. Until `until`, focus events for another window of the same app are
    /// the app re-raising its old key window, not the user's choice.
    private var focusTarget: (id: CGWindowID, pid: pid_t, until: Date)?
    var monitor: Monitor { monitors[monitorIndex] }
    var tab: Tab { monitor.tab }
    var tabs: [Tab] { monitor.tabs }
    var tabIndex: Int { monitor.tabIndex }
    /// Most recently focused first.
    private(set) var mru: [CGWindowID] = []
    /// Largest minimum window size seen per app; new windows of the app start with it.
    private(set) var minimums: [String: CGSize] = [:]
    private var started = false
    /// Set for a restart: quit without bringing parked windows back.
    var keepWindowsOnQuit = false
    /// jwm manages, per display, the Space it showed at start, and leaves other Spaces alone (AX only
    /// reports windows on current Spaces, so managing several would scramble the layout).
    var onHomeSpace: Bool { monitors.isEmpty || monitor.atHome }
    private var refreshScheduled = false
    private var saveScheduled = false
    /// Panes that windows were showing in when they went away (minimized, native full screen), so
    /// they return there instead of to the selected pane.
    private var vacated: [CGWindowID: Pane] = [:]
    /// Guards against apps whose size never settles making layout() recurse forever.
    private var layoutDepth = 0
    /// layout() requests are merged: a burst of fast commands costs one pass over the windows.
    private var layoutScheduled = false
    /// Windows that reported a move/resize, checked once things settle.
    private var movedWindows = Set<CGWindowID>()
    private var frameCheckScheduled = false
    /// Focus events caused by our own focusing are ignored until this time.
    private var ignoreFocusUntil = Date.distantPast

    lazy var border = Border()
    lazy var bufferList = BufferList()
    lazy var palette = CommandPalette()

    // MARK: Lifecycle

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            self.scheduleRefresh(after: 0.3)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            self.scheduleRefresh()
        }
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let watcher = self.apps[app.processIdentifier],
                  let window = watcher.element.element(kAXFocusedWindowAttribute) else { return }
            self.userFocused(window)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in self.displaysChanged() }
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            self.spaceChanged()
        }
        minimums = loadMinimums()
        syncMonitors()

        refresh()
        // Seed recency from the on-screen stacking order (front to back).
        let stack = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        mru = stack.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }.filter { windows[$0] != nil }
        // No saved layout: start from where the windows are now.
        adopt()
        started = true
        layout()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in self.refresh() }
    }

    private func spaceChanged() {
        if monitors.allSatisfy(\.atHome) {
            refresh()
            forceLayout()
        } else {
            updateChrome()
            if !monitor.atHome { Hud.shared.flash("jwm is paused on this desktop") }
        }
        StatusBar.shared.update()
    }

    /// Forgets all tabs and splits and builds the layout again from where the windows are now.
    func resetLayout() {
        for m in monitors {
            m.tabs = [Tab()]
            m.tabIndex = 0
        }
        adopt()
        forceLayout()
    }

    // MARK: Displays

    /// Windows (front to back) that show at least half their area, sampled on a grid, above
    /// `minArea`. These are what the user sees, so they become panes.
    private func visibleWindows(_ stack: [(id: CGWindowID, frame: CGRect)], minArea: CGFloat)
        -> [(id: CGWindowID, frame: CGRect)] {
        var out: [(id: CGWindowID, frame: CGRect)] = []
        for (i, w) in stack.enumerated() where w.frame.width * w.frame.height >= minArea {
            let above = stack[..<i].map(\.frame)
            var seen = 0, total = 0
            for gx in 0..<12 {
                for gy in 0..<12 {
                    let p = CGPoint(x: w.frame.minX + w.frame.width * (CGFloat(gx) + 0.5) / 12,
                                    y: w.frame.minY + w.frame.height * (CGFloat(gy) + 0.5) / 12)
                    total += 1
                    if !above.contains(where: { $0.contains(p) }) { seen += 1 }
                }
            }
            if seen * 2 >= total { out.append(w) }
        }
        return out
    }

    /// Displays were added, removed, rearranged or resized. Sync now, and again once macOS has
    /// finished moving windows between displays.
    private func displaysChanged() {
        displaysSettleUntil = Date().addingTimeInterval(1.5)
        syncMonitors()
        forceLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.syncMonitors()
            self.refresh()
            self.forceLayout()
        }
    }

    /// Matches `monitors` to the connected displays.
    /// - A display that disconnects hands its tabs to the main display, after the main display's own
    ///   tabs (`⌘D ]` shows them). Its windows are hidden until then.
    /// - When it reconnects, those tabs go back to it, with any changes made meanwhile.
    /// - After displays are added or removed, each display manages the Space it shows now.
    func syncMonitors() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let selected = monitors.isEmpty ? nil : monitor
        let selectedTabs = Dictionary(uniqueKeysWithValues: monitors.map { (ObjectIdentifier($0), $0.tab) })
        let uuids = Set(screens.map(displayUUID))
        let gone = monitors.filter { !uuids.contains($0.uuid) }
        var reattached: [Monitor] = []
        var next: [Monitor] = []
        for screen in screens {
            let uuid = displayUUID(screen)
            let m: Monitor
            if let known = monitors.first(where: { $0.uuid == uuid }) {
                m = known
            } else if let back = detached.removeValue(forKey: uuid) {
                m = back
                reattached.append(m)
            } else {
                m = Monitor(uuid: uuid)
                if !monitors.isEmpty { reattached.append(m) }
            }
            m.frame = flipped(screen.frame)
            m.visible = flipped(screen.visibleFrame)
            next.append(m)
        }
        let changed = !gone.isEmpty || !reattached.isEmpty
        monitors = next

        // Disconnected displays: their tabs move to the main display.
        if let main = monitors.first, !gone.isEmpty {
            let first = main.tabs.count
            for g in gone {
                for t in g.tabs {
                    t.origin = g.uuid
                    t.zoomed = nil
                }
                main.tabs.append(contentsOf: g.tabs)
                g.tabs = [Tab()]
                g.tabIndex = 0
                detached[g.uuid] = g
            }
            Hud.shared.flash("Display disconnected · its layout is tab \(first + 1) (⌘D ])")
        }
        // Reconnected displays: take their tabs back.
        for m in reattached {
            let mine = monitors.flatMap(\.tabs).filter { $0.origin == m.uuid }
            guard !mine.isEmpty else { continue }
            for o in monitors where o !== m {
                let current = o.tab
                o.tabs.removeAll { $0.origin == m.uuid }
                if o.tabs.isEmpty { o.tabs = [Tab()] }
                o.tabIndex = o.tabs.firstIndex { $0 === current } ?? min(o.tabIndex, o.tabs.count - 1)
            }
            for t in mine { t.origin = nil }
            m.tabs = mine
            m.tabIndex = 0
        }
        // Keep each display on the tab it showed, if it still has it.
        for m in monitors {
            if let t = selectedTabs[ObjectIdentifier(m)], let i = m.tabs.firstIndex(where: { $0 === t }) { m.tabIndex = i }
        }
        if changed {
            for m in monitors { m.homeSpace = currentSpace(display: m.uuid) }
        }
        monitorIndex = selected.flatMap { s in monitors.firstIndex { $0 === s } } ?? 0
        // A window can only be in one place on screen.
        for m in monitors { dedupe(m) }
        StatusBar.shared.update()
    }

    /// Display whose full frame holds `point`, else the nearest one.
    private func monitorAt(_ point: CGPoint) -> Monitor? {
        if let m = monitors.first(where: { $0.frame.contains(point) }) { return m }
        return monitors.min { a, b in
            hypot(a.frame.midX - point.x, a.frame.midY - point.y) < hypot(b.frame.midX - point.x, b.frame.midY - point.y)
        }
    }

    private func monitorFor(_ frame: CGRect) -> Monitor? { monitorAt(CGPoint(x: frame.midX, y: frame.midY)) }

    /// Which display and tab show `id`, preferring the visible tab of each display.
    private func location(of id: CGWindowID) -> (Monitor, Tab, Pane)? {
        for m in monitors {
            if let pane = m.tab.panes.first(where: { $0.current == id }) { return (m, m.tab, pane) }
        }
        for m in monitors {
            for t in m.tabs { if let pane = t.panes.first(where: { $0.current == id }) { return (m, t, pane) } }
        }
        return nil
    }

    /// Builds each display's layout from where its windows are now, so starting jwm moves them as
    /// little as possible: windows that are mostly visible (not buried under others) become panes in a
    /// split tree that matches their positions and sizes. Buried windows become hidden buffers.
    private func adopt() {
        let order = Dictionary(uniqueKeysWithValues: mru.enumerated().map { ($1, $0) })
        var placed = Set<CGWindowID>()
        for m in monitors {
            let tab = m.tab
            let here = windows.values.compactMap { w -> (id: CGWindowID, frame: CGRect)? in
                guard let frame = w.element.frame, isMostlyOnScreen(frame), monitorFor(frame) === m else { return nil }
                return (w.id, frame.intersection(m.visible))
            }.filter { !$0.frame.isNull }
            let stack = here.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            let shown = visibleWindows(stack, minArea: m.visible.width * m.visible.height * 0.03)
            guard let root = inferLayout(shown, in: m.visible, tolerance: max(40, gap * 4)) else { continue }
            tab.root = root
            root.parent = nil
            tab.focused = tab.panes.first { $0.current == stack.first?.id } ?? tab.panes[0]
            placed.formUnion(tab.panes.compactMap(\.current))
        }
        let focusedID = frontmostWindow()?.id ?? mru.first
        if let id = focusedID, let (m, _, _) = location(of: id), let i = monitors.firstIndex(where: { $0 === m }) {
            monitorIndex = i
            m.tab.focused = m.tab.panes.first { $0.current == id } ?? m.tab.focused
        }
        log("adopted \(placed.count) of \(windows.count) windows on \(monitors.count) display(s)")
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.saveScheduled = false
            self.saveState()
        }
    }

    /// Puts parked windows back where they were before jwm started (or centered).
    /// Also used by `jwm --restore` after a crash.
    func restoreAll() {
        let screen = monitors.first?.visible ?? screenBounds()
        for window in windows.values {
            guard var frame = window.element.frame, window.parked || !isMostlyOnScreen(frame) else { continue }
            if let home = window.home {
                frame = home
            } else {
                frame.size.width = min(frame.width, screen.width)
                frame.size.height = min(frame.height, screen.height)
                frame.origin = CGPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            }
            window.setFrame(frame)
        }
    }

    private func isMostlyOnScreen(_ frame: CGRect) -> Bool {
        let screens = monitors.isEmpty ? NSScreen.screens.map { flipped($0.frame) } : monitors.map(\.frame)
        let visible = screens.reduce(CGFloat(0)) { sum, s in
            let r = frame.intersection(s)
            return sum + (r.isNull ? 0 : r.width * r.height)
        }
        return visible >= frame.width * frame.height * 0.3
    }

    // MARK: Window tracking

    func scheduleRefresh(after delay: Double = 0.1) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.refreshScheduled = false
            self.refresh()
        }
    }

    /// Reconciles our window table with what the apps report.
    func refresh() {
        if started && !monitors.contains(where: \.atHome) { return }
        let start = Date()
        defer {
            let ms = Date().timeIntervalSince(start) * 1000
            if ms > 30 { log(String(format: "refresh took %.0f ms", ms)) }
        }
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        let pids = Set(running.map(\.processIdentifier))
        for pid in apps.keys where !pids.contains(pid) { apps[pid] = nil }
        for app in running where apps[app.processIdentifier] == nil {
            apps[app.processIdentifier] = AppWatcher(app)
        }

        var seen = Set<CGWindowID>()
        var added: [CGWindowID] = []
        for watcher in apps.values {
            guard let elements = watcher.element.elements(kAXWindowsAttribute) else {
                // App didn't answer; assume its windows are unchanged.
                seen.formUnion(windows.values.filter { $0.pid == watcher.pid }.map(\.id))
                continue
            }
            for element in elements {
                guard let id = element.windowID else { continue }
                // Known windows only need the checks that can change (2 AX calls instead of 4).
                if windows[id] != nil {
                    if Window.isStillManageable(element) { seen.insert(id) }
                    continue
                }
                guard Window.isManageable(element) else { continue }
                // A display showing another Space: its windows there aren't ours. Skip them for now.
                if started, let f = element.frame, let m = monitorFor(f), !m.atHome { continue }
                seen.insert(id)
                if windows[id] == nil {
                    let window = Window(id: id, element: element, pid: watcher.pid,
                                        app: watcher.element, appName: watcher.name)
                    if let frame = element.frame, isMostlyOnScreen(frame) { window.home = frame }
                    window.minSize = minimums[watcher.name] ?? .zero
                    windows[id] = window
                    watcher.watch(element)
                    added.append(id)
                }
            }
        }
        // While a display shows another Space, AX doesn't report the windows on that display's home
        // Space, nor parked windows if that display holds the park corner. Keep those.
        let paused = monitors.filter { !$0.atHome }
        let shielded = { (w: Window) -> Bool in
            guard self.started, !paused.isEmpty else { return false }
            if w.parked { return true }
            if let (m, _, _) = self.location(of: w.id), paused.contains(where: { $0 === m }) { return true }
            guard let e = w.expected, let m = self.monitorFor(e) else { return false }
            return paused.contains { $0 === m }
        }
        let removed = windows.keys.filter { !seen.contains($0) && !(windows[$0].map(shielded) ?? false) }
        for id in removed { forget(id) }

        guard started, !(added.isEmpty && removed.isEmpty) else { return }
        for id in added {
            // A window coming back (un-minimized, left full screen) returns to its pane.
            if let pane = vacated.removeValue(forKey: id),
               let i = monitors.firstIndex(where: { $0.tab.panes.contains { $0 === pane } }) {
                monitorIndex = i
                if tab.zoomed != nil, tab.zoomed !== pane { tab.zoomed = nil }
                tab.focused = pane
            } else if let frame = windows[id]?.element.frame, isMostlyOnScreen(frame),
                      let m = monitorFor(frame), let i = monitors.firstIndex(where: { $0 === m }), m.atHome {
                // A new window opens on the display it appeared on.
                monitorIndex = i
            }
            // New windows open in the selected pane, like Emacs displaying a new buffer.
            display(id)
        }
        layout()
    }

    private func forget(_ id: CGWindowID) {
        if started, let (_, _, pane) = location(of: id) {
            if vacated.count > 100 { vacated.removeAll() }
            vacated[id] = pane
        }
        windows[id] = nil
        mru.removeAll { $0 == id }
        for m in monitors {
            for tab in m.tabs {
                for pane in tab.panes where pane.remove(id) {
                    fallback(pane, in: tab)
                }
            }
        }
    }

    private func frontmostWindow() -> Window? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = apps[pid]?.element.element(kAXFocusedWindowAttribute)?.windowID else { return nil }
        return windows[id]
    }

    func axEvent(_ notification: String, _ element: AXUIElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            // Windows often get their subrole a moment after creation.
            scheduleRefresh(after: 0.15)
        case kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification:
            scheduleRefresh(after: 0.05)
        case kAXFocusedWindowChangedNotification:
            userFocused(element)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            frameChanged(element)
        default:
            break
        }
    }

    /// The user focused a window (click, Cmd-Tab, app activation).
    private func userFocused(_ element: AXUIElement) {
        guard started, !monitors.isEmpty, Date() > ignoreFocusUntil, let id = element.windowID else { return }
        guard let focusedWindow = windows[id] else { scheduleRefresh(); return }
        if let target = focusTarget {
            if target.id == id {
                focusTarget = nil
            } else if Date() < target.until, focusedWindow.pid == target.pid {
                // The app brought back its previous key window while jwm focused another one of its
                // windows. Put focus back on the one jwm chose.
                windows[target.id]?.focus()
                return
            }
        }
        // A window on a display that shows another Space: not ours to manage right now.
        if !focusedWindow.parked, let f = focusedWindow.element.frame, let m = monitorFor(f), !m.atHome { return }
        // A visible window just closed or minimized and macOS is focusing some other window in
        // response. That's not the user's choice: ignore it and let refresh() fall back through
        // the pane's history (like Emacs kill-buffer), then refocus the selected pane.
        let vanishing = monitors.flatMap { $0.tab.visiblePanes }.contains { pane in
            guard let current = pane.current, current != id, let window = windows[current] else { return false }
            return window.element.string(kAXRoleAttribute) == nil || window.element.bool(kAXMinimizedAttribute) == true
        }
        if vanishing {
            scheduleRefresh()
            return
        }
        touch(id)
        for (i, m) in monitors.enumerated() {
            guard let pane = m.tab.visiblePanes.first(where: { $0.current == id }) else { continue }
            if pane !== m.tab.focused || i != monitorIndex {
                monitorIndex = i
                m.tab.focused = pane
                updateChrome()
            }
            return
        }
        // Focused a window that isn't on screen: switch to it in the selected pane (on a display jwm
        // manages right now).
        if !monitor.atHome, let i = monitors.firstIndex(where: \.atHome) { monitorIndex = i }
        display(id)
        layout()
    }

    // MARK: External moves and resizes

    private func frameChanged(_ element: AXUIElement) {
        guard started, !monitors.isEmpty, let id = element.windowID, let window = windows[id],
              Date() > window.ownChangeUntil, Date() > displaysSettleUntil, !layoutScheduled else { return }
        movedWindows.insert(id)
        scheduleFrameCheck()
    }

    private func scheduleFrameCheck() {
        guard !frameCheckScheduled else { return }
        frameCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.frameCheckScheduled = false
            // Wait until the user lets go of a drag.
            if NSEvent.pressedMouseButtons & 1 != 0 { return self.scheduleFrameCheck() }
            // A display that just disconnected moves its windows before the screen-change notice.
            if Set(NSScreen.screens.map(displayUUID)) != Set(self.monitors.map(\.uuid)) { self.syncMonitors() }
            let ids = self.movedWindows
            self.movedWindows.removeAll()
            var relayout = false
            for id in ids {
                if let window = self.windows[id], self.checkFrame(window) { relayout = true }
            }
            if relayout { self.layout() }
        }
    }

    /// Reacts to a window ending up somewhere other than where we put it. Returns true if the
    /// layout itself changed and needs reapplying.
    private func checkFrame(_ window: Window) -> Bool {
        guard let actual = window.element.frame else { return false }
        let close = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
                && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }

        if let expected = window.expected {
            if close(actual, expected) { return false }
            // Dropped on another display (drag, Raycast "Next Display", …): move it there.
            if let (from, _, pane) = location(of: window.id), let to = monitorFor(actual), to !== from,
               send(window.id, from: from, pane: pane, to: to, frame: actual) {
                return true
            }
            // Not in a visible pane (its display or tab went away): lay out again, which hides it.
            guard let (m, t, pane) = location(of: window.id), t === m.tab, m.atHome,
                  t.visiblePanes.contains(where: { $0 === pane }) else { return true }
            // A changed edge (mouse drag, Raycast "left 2/3", …) resizes the pane.
            if t.adjust(pane, from: expected, to: actual, bounds: layoutBounds(m), inset: gap / 2,
                        minimum: paneMinimum) {
                log("\(window.label) resized externally → adjusted splits")
                return true
            }
            // Moved to a new place (Raycast "left half" on a right-hand window, …): change the layout to match.
            if follow(pane, in: m, to: actual) { return true }
            // A shape the split tree can't express: put it back.
            correct(window) { $0.setFrame(expected) }
        } else if window.parked {
            // Something pulled a parked buffer back on screen.
            guard isMostlyOnScreen(actual) else { return false }
            correct(window) { $0.park(at: self.parkPoint) }
        }
        return false
    }

    /// Changes the layout so the window in `pane` sits where something else (Raycast, Rectangle, a drag)
    /// put it. Returns true if the layout changed.
    /// - fills the screen → maximize the pane (⌘D f restores the layout)
    /// - mostly covers another pane → swap the two windows
    /// - a screen side (left/right/top/bottom half, 2/3, …) → move the pane to that side of the tab
    private func follow(_ pane: Pane, in m: Monitor, to actual: CGRect) -> Bool {
        let tab = m.tab
        let screen = m.visible
        let tol = gap + 16
        let l = abs(actual.minX - screen.minX) <= tol, r = abs(actual.maxX - screen.maxX) <= tol
        let t = abs(actual.minY - screen.minY) <= tol, b = abs(actual.maxY - screen.maxY) <= tol

        if l && r && t && b {
            guard tab.panes.count > 1, tab.zoomed !== pane else { return false }
            tab.zoomed = pane
            tab.focused = pane
            log("followed: maximize")
            return true
        }
        if tab.zoomed != nil { tab.zoomed = nil }

        // Swap with the pane the window now mostly covers.
        let area = { (rect: CGRect) in rect.isNull ? 0 : rect.width * rect.height }
        let overlap = { (rect: CGRect) in area(rect.intersection(actual)) / max(1, area(rect.union(actual))) }
        let rects = paneRects(m)
        if let (target, rect) = rects.filter({ $0.0 !== pane }).max(by: { overlap($0.1) < overlap($1.1) }),
           overlap(rect) >= 0.6, overlap(rect) > overlap(rects.first { $0.0 === pane }?.1 ?? .null) {
            let mine = pane.current, theirs = target.current
            if let mine { target.show(mine) }
            if let theirs { pane.show(theirs) } else { pane.clear() }
            tab.focused = target
            // "Left 2/3" onto a half pane: also move the split line.
            _ = tab.adjust(target, from: rect, to: actual, bounds: layoutBounds(m), inset: gap / 2, minimum: paneMinimum)
            log("followed: swap panes")
            return true
        }

        // Dock against one side of the screen.
        let side: (vertical: Bool, first: Bool, ratio: CGFloat)?
        switch (l, r, t, b) {
        case (true, false, true, true): side = (true, true, actual.width / screen.width)
        case (false, true, true, true): side = (true, false, actual.width / screen.width)
        case (true, true, true, false): side = (false, true, actual.height / screen.height)
        case (true, true, false, true): side = (false, false, actual.height / screen.height)
        default: side = nil
        }
        guard let side else { return false }
        let partner = { () -> Pane in
            let fresh = Pane()
            if let id = self.otherBuffer(in: tab) { fresh.show(id) }
            return fresh
        }
        tab.dock(pane, vertical: side.vertical, first: side.first, ratio: side.ratio, partner: partner)
        log("followed: dock \(side)")
        return true
    }

    /// Moves `id` from its pane on `from` to the display `to`. The old pane falls back through its
    /// history, like an Emacs window after its buffer moves to another frame.
    /// With `frame` (where something dropped it), it lands where it was dropped: full screen → that
    /// display's pane maximized; against a side → a new pane on that side; else the pane under it.
    /// Without `frame` (⌘D m), it goes to an empty pane there, else the selected pane.
    @discardableResult
    private func send(_ id: CGWindowID, from: Monitor, pane: Pane, to: Monitor, frame: CGRect?) -> Bool {
        guard to.atHome, let i = monitors.firstIndex(where: { $0 === to }) else {
            Hud.shared.flash("jwm is paused on that display's desktop")
            return false
        }
        _ = pane.remove(id)
        fallback(pane, in: from.tab)
        monitorIndex = i
        let tab = to.tab
        tab.zoomed = nil
        windows[id]?.expected = nil
        guard let frame else {
            if let empty = tab.panes.first(where: { $0.current == nil }) { tab.focused = empty }
            display(id)
            log("sent window \(id) to display \(i + 1)")
            return true
        }

        let screen = to.visible
        let tol = gap + 16
        let l = abs(frame.minX - screen.minX) <= tol, r = abs(frame.maxX - screen.maxX) <= tol
        let t = abs(frame.minY - screen.minY) <= tol, b = abs(frame.maxY - screen.maxY) <= tol
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let under = paneRects(to).first { $0.1.insetBy(dx: -gap, dy: -gap).contains(center) }?.0

        let side: (vertical: Bool, first: Bool, ratio: CGFloat)?
        switch (l, r, t, b) {
        case (true, false, true, true): side = (true, true, frame.width / screen.width)
        case (false, true, true, true): side = (true, false, frame.width / screen.width)
        case (true, true, true, false): side = (false, true, frame.height / screen.height)
        case (true, true, false, true): side = (false, false, frame.height / screen.height)
        default: side = nil
        }
        let rootIsEmpty = (tab.root as? Pane)?.current == nil
        if let side, !rootIsEmpty {
            let fresh = Pane()
            fresh.show(id)
            touch(id)
            tab.dock(fresh, vertical: side.vertical, first: side.first, ratio: side.ratio) { Pane() }
            log("sent window \(id) to display \(i + 1), docked \(side)")
            return true
        }
        tab.focused = under ?? tab.panes.first { $0.current == nil } ?? tab.focused
        display(id)
        if l && r && t && b, tab.panes.count > 1 { tab.zoomed = tab.focused }
        log("sent window \(id) to display \(i + 1)")
        return true
    }

    /// ⌘D o-style command for displays: send the selected pane's window to the next display.
    func sendToNextDisplay(_ dir: Int) {
        guard monitors.count > 1 else { return Hud.shared.flash("Only one display") }
        let from = monitor, pane = tab.focused
        guard let id = pane.current else { return Hud.shared.flash("Empty pane") }
        let to = monitors[(monitorIndex + dir + monitors.count) % monitors.count]
        if send(id, from: from, pane: pane, to: to, frame: nil) {
            Hud.shared.flash("Sent to display \((monitors.firstIndex { $0 === to } ?? 0) + 1)")
            layout()
        }
    }

    /// Moves the selection to the next display, like Emacs other-frame.
    func focusDisplay(_ dir: Int) {
        guard monitors.count > 1 else { return Hud.shared.flash("Only one display") }
        monitorIndex = (monitorIndex + dir + monitors.count) % monitors.count
        guard monitor.atHome else { return Hud.shared.flash("jwm is paused on that display's desktop") }
        focusSelected()
    }

    /// Applies a correction at most once a second per window, rechecking later instead of dropping
    /// it, and gives up after a few back-to-back attempts so we don't fight an app forever.
    private func correct(_ window: Window, _ fix: (Window) -> Void) {
        let since = Date().timeIntervalSince(window.lastCorrection)
        if since > 5 { window.corrections = 0 }
        guard window.corrections < 3 else { return log("giving up on \(window.label)") }
        guard since >= 1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 - since) {
                self.movedWindows.insert(window.id)
                self.scheduleFrameCheck()
            }
            return
        }
        window.corrections += 1
        window.lastCorrection = Date()
        log("correcting \(window.label)")
        fix(window)
    }

    private func touch(_ id: CGWindowID) {
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
    }

    // MARK: Buffers and panes

    /// Whether `id` can be shown in `pane` without also being visible in another pane of `tab`, or in
    /// another display's visible tab (one window can only be in one place on screen).
    private func available(_ id: CGWindowID, in tab: Tab, for pane: Pane?) -> Bool {
        guard windows[id] != nil, !tab.panes.contains(where: { $0 !== pane && $0.current == id }) else { return false }
        return !monitors.contains { m in m.tab !== tab && m.tab.panes.contains { $0 !== pane && $0.current == id } }
    }

    /// Points `pane` at a showable entry after its current one went away.
    private func fallback(_ pane: Pane, in tab: Tab) {
        let ok = { (id: CGWindowID) in self.available(id, in: tab, for: pane) }
        if let current = pane.current, ok(current) { return }
        if pane.step(-1, where: ok) || pane.step(1, where: ok) { return }
        pane.clear()
    }

    /// Shows `id` in the selected pane, taking it away from any other visible pane (this tab, or
    /// another display's visible tab).
    func display(_ id: CGWindowID) {
        let pane = tab.focused
        pane.show(id)
        touch(id)
        for m in monitors {
            for other in m.tab.panes where other !== pane && other.current == id {
                fallback(other, in: m.tab)
            }
        }
    }

    /// Emacs other-buffer: the most recent window not visible in this tab.
    private func otherBuffer(in tab: Tab? = nil, where fits: @escaping (CGWindowID) -> Bool = { _ in true }) -> CGWindowID? {
        let tab = tab ?? self.tab
        let ok = { (id: CGWindowID) in self.available(id, in: tab, for: nil) && fits(id) }
        return mru.first(where: ok) ?? windows.keys.sorted().first(where: ok)
    }

    /// Buffers for the buffer list: not-visible ones in MRU order first, then visible ones.
    func bufferOrder() -> [(Window, visible: Bool)] {
        let visible = Set(monitors.flatMap { $0.tab.panes.compactMap(\.current) })
        let ordered = mru + windows.keys.filter { !mru.contains($0) }.sorted()
        let hidden = ordered.filter { !visible.contains($0) }
        let shown = ordered.filter { visible.contains($0) }
        return (hidden.map { ($0, false) } + shown.map { ($0, true) }).compactMap { id, vis in
            windows[id].map { ($0, vis) }
        }
    }

    // MARK: Layout

    /// The selected display's screen, for overlays (HUD, pickers).
    var currentScreen: NSScreen? { monitors.isEmpty ? nil : monitor.screen }

    /// Visible frame of the primary screen in AX coordinates.
    func screenBounds() -> CGRect {
        flipped(NSScreen.screens.first?.visibleFrame ?? .zero)
    }

    /// Area panes are laid out in: the display minus half a gap (each window insets the other half).
    private func layoutBounds(_ m: Monitor) -> CGRect { m.visible.insetBy(dx: gap / 2, dy: gap / 2) }

    /// Where parked windows go: a display's bottom-right corner such that no other display reaches
    /// into the area right of and below it, so a window there is off every screen except a 1px sliver.
    var parkPoint: CGPoint {
        let frames = monitors.isEmpty ? NSScreen.screens.map { flipped($0.frame) } : monitors.map(\.frame)
        // Parking moves a window onto that display's current Space, so only use displays jwm manages
        // right now (a parked window on another Space would be lost when that Space hides).
        let home = monitors.isEmpty ? frames : monitors.filter(\.atHome).map(\.frame)
        let clear = home.filter { corner in
            !frames.contains { $0 != corner && $0.maxX > corner.maxX - 1 && $0.maxY > corner.maxY - 1 }
        }
        let corner = clear.max { $0.maxX + $0.maxY < $1.maxX + $1.maxY }
            ?? frames.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: corner.maxX - 1, y: corner.maxY - 1)
    }

    /// Smallest pane that fits its window's learned minimum size.
    private func paneMinimum(_ pane: Pane) -> CGSize {
        guard let id = pane.current, let size = windows[id]?.minSize, size != .zero else { return .zero }
        return CGSize(width: size.width + gap, height: size.height + gap)
    }

    /// Window frames for a display's visible tab (default: the selected display).
    private func paneRects(_ m: Monitor? = nil) -> [(Pane, CGRect)] {
        let m = m ?? monitor
        let half = gap / 2
        return m.tab.rects(in: layoutBounds(m), minimum: paneMinimum).map { ($0, $1.insetBy(dx: half, dy: half)) }
    }

    /// Moves every window to where the current tab says it belongs and focuses the selected pane.
    /// Runs on the next main-loop turn, once for any number of calls before then, so commands that
    /// arrive faster than the windows can move do not queue up one full layout each.
    func layout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async {
            self.layoutScheduled = false
            self.layoutNow()
        }
    }

    /// Like layout(), but also re-applies frames of windows that seem to be in place already.
    func forceLayout() {
        for window in windows.values { window.expected = nil }
        layout()
    }

    private func layoutNow() {
        guard started, !monitors.isEmpty else { return }
        let start = Date()
        defer {
            let ms = Date().timeIntervalSince(start) * 1000
            if ms > 30 { log(String(format: "layout took %.0f ms", ms)) }
        }
        var frames: [CGWindowID: (CGRect, Monitor)] = [:]
        // Displays showing another Space are left alone, and so are the windows on them.
        var paused = Set<CGWindowID>()
        for m in monitors {
            guard m.atHome else {
                for w in windows.values where !w.parked {
                    if let f = w.element.frame, monitorFor(f) === m { paused.insert(w.id) }
                }
                continue
            }
            for (pane, rect) in paneRects(m) {
                if let id = pane.current { frames[id] = (rect, m) }
            }
        }
        let hide = parkPoint
        var learned = false
        for window in windows.values where !paused.contains(window.id) {
            if let (rect, m) = frames[window.id] {
                learned = place(window, in: rect, on: m) || learned
            } else if !window.parked || window.parkedAt != hide {
                window.park(at: hide)
            }
        }
        // A window refused its size: lay out again with its minimum taken into account.
        if learned && layoutDepth < 3 {
            layoutDepth += 1
            defer { layoutDepth -= 1 }
            return layoutNow()
        }
        if monitor.atHome { focusSelected() } else { updateChrome() }
        scheduleSave()
    }

    /// Puts `window` in `rect`, never smaller than its minimum size and never hanging off screen
    /// (if the panes can't all fit, windows overlap their neighbours instead). Returns true if
    /// the window turned out to have a larger minimum size than we knew.
    private func place(_ window: Window, in rect: CGRect, on m: Monitor) -> Bool {
        let bounds = m.visible.insetBy(dx: gap, dy: gap)
        var frame = rect
        frame.size.width = min(max(frame.width, window.minSize.width), bounds.width)
        frame.size.height = min(max(frame.height, window.minSize.height), bounds.height)
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        // Already there: no AX calls. External moves are caught by checkFrame, and forceLayout()
        // re-applies everything.
        if !window.parked, window.expected == frame { return false }
        window.setFrame(frame)

        guard let actual = window.element.frame else { return false }
        log("place \(window.label) \(frame) → \(actual)")
        var minimum = window.minSize
        if actual.width > frame.width + 1 { minimum.width = actual.width }
        if actual.height > frame.height + 1 { minimum.height = actual.height }
        guard minimum != window.minSize else { return false }
        window.minSize = minimum
        let known = minimums[window.appName] ?? .zero
        minimums[window.appName] = CGSize(width: max(known.width, minimum.width),
                                          height: max(known.height, minimum.height))
        log("\(window.label) minimum size \(minimum)")
        return true
    }

    func focusSelected() {
        ignoreFocusUntil = Date().addingTimeInterval(0.3)
        if let id = tab.focused.current, let window = windows[id] {
            focusTarget = (id, window.pid, Date().addingTimeInterval(0.6))
            window.focus()
            // Apps can take a moment to activate and then raise their old key window: check once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let target = self.focusTarget, target.id == id,
                      window.app.element(kAXFocusedWindowAttribute)?.windowID != id else { return }
                window.focus()
            }
        } else {
            // Empty pane: take keyboard focus so typing doesn't go to a parked window.
            NSApp.activate(ignoringOtherApps: true)
        }
        updateChrome()
    }

    /// Focus border and menu bar title.
    private func updateChrome() {
        StatusBar.shared.update()
        guard !monitors.isEmpty, monitor.atHome else { border.hide(); return }
        let rects = paneRects()
        guard let (pane, rect) = rects.first(where: { $0.0 === tab.focused }),
              rects.count > 1 || pane.current == nil else {
            border.hide()
            return
        }
        let frame = pane.current.flatMap { windows[$0]?.expected } ?? rect
        border.show(around: flipped(frame), empty: pane.current == nil)
    }

    /// Tree, pane histories and focus; printed on SIGUSR1.
    func dump() -> String {
        func name(_ id: CGWindowID?) -> String { id.flatMap { windows[$0]?.label } ?? "∅" }
        func describe(_ node: Node, _ depth: Int) -> String {
            let pad = String(repeating: "  ", count: depth)
            if let pane = node as? Pane {
                let history = pane.history.map { $0 == pane.current ? "[\(name($0))]" : name($0) }
                return pad + (pane === tab.focused ? "* " : "- ") + history.joined(separator: " ⇄ ") + "\n"
            }
            let split = node as! Split
            return pad + (split.vertical ? "| " : "— ") + String(format: "%.2f", split.ratio) + "\n"
                + describe(split.a, depth + 1) + describe(split.b, depth + 1)
        }
        return monitors.enumerated().map { i, m in
            "display \(i + 1)\(i == monitorIndex ? " *" : "")\(m.atHome ? "" : " (paused)") · tab \(m.tabIndex + 1)/\(m.tabs.count)"
                + "\(m.tab.zoomed != nil ? " (zoomed)" : "")\n" + describe(m.tab.root, 0)
        }.joined()
    }

    // MARK: Commands

    func command(_ key: Int, shift: Bool) {
        log("command key=\(key)")
        guard onHomeSpace || key == kVK_ANSI_D || key == kVK_ANSI_N else {
            return Hud.shared.flash("jwm is paused on this desktop · ⌘D n for the next display")
        }
        guard let command = WM.commands.first(where: { $0.keys.contains(key) }) else {
            return Hud.shared.flash("⌘D … is undefined · ⌘D x for commands")
        }
        command.run(self)
    }

    func showPalette() {
        palette.show { command in
            command?.run(self)
            // Hand focus back to the selected pane unless the command did, or opened another picker.
            DispatchQueue.main.async {
                if NSApp.isActive, !NSApp.windows.contains(where: \.isKeyWindow) { self.focusSelected() }
            }
        }
    }

    func split(vertical: Bool) {
        tab.zoomed = nil
        // Like Emacs, refuse to split a pane whose window wouldn't fit in half of it.
        var half = CGFloat.infinity
        if let rect = paneRects().first(where: { $0.0 === tab.focused })?.1 {
            half = ((vertical ? rect.width : rect.height) - gap) / 2
        }
        let length = { (id: CGWindowID) -> CGFloat in
            guard let size = self.windows[id]?.minSize else { return 0 }
            return vertical ? size.width : size.height
        }
        if let id = tab.focused.current, length(id) > half {
            return Hud.shared.flash("Not enough room to split this pane")
        }
        let fresh = Pane()
        if let id = otherBuffer(where: { length($0) <= half }) { fresh.show(id) }
        tab.split(tab.focused, vertical: vertical, with: fresh)
        layout()
    }

    func deletePane() {
        tab.zoomed = nil
        guard let next = tab.delete(tab.focused) else { return Hud.shared.flash("Can't delete the only pane") }
        tab.focused = next
        layout()
    }

    func deleteOtherPanes() {
        tab.zoomed = nil
        tab.root = tab.focused
        tab.focused.parent = nil
        layout()
    }

    /// ⌥Tab / ⌥⇧Tab: next / previous pane, continuing onto the other displays. Displays go left to
    /// right; a zoomed tab counts as its one visible pane; paused displays are skipped.
    func focusPane(_ dir: Int) {
        let ring = monitors.filter(\.atHome)
            .sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
            .flatMap { m in m.tab.visiblePanes.map { (m, $0) } }
        guard ring.count > 1 else { return }
        let i = ring.firstIndex { $0.0 === monitor && $0.1 === tab.focused } ?? 0
        let (m, pane) = ring[(i + dir + ring.count) % ring.count]
        if let mi = monitors.firstIndex(where: { $0 === m }) { monitorIndex = mi }
        m.tab.focused = pane
        focusSelected()
    }

    func walkHistory(_ dir: Int) {
        let pane = tab.focused
        guard pane.step(dir, where: { available($0, in: tab, for: pane) }) else {
            return Hud.shared.flash(dir < 0 ? "Beginning of history" : "End of history")
        }
        if let id = pane.current { touch(id) }
        layout()
    }

    func showBufferList() {
        bufferList.show(bufferOrder()) { window in
            if let window { self.display(window.id) }
            self.layout()
        }
    }

    func toggleZoom() {
        tab.zoomed = tab.zoomed == nil ? tab.focused : nil
        layout()
    }

    func killBuffer() {
        guard let id = tab.focused.current, let window = windows[id] else { return }
        window.close()
        scheduleRefresh(after: 0.3)
    }

    func newTab() {
        monitor.tabs.insert(Tab(), at: tabIndex + 1)
        monitor.tabIndex += 1
        dedupe(monitor)
        layout()
        announceTab()
    }

    func closeTab() {
        guard tabs.count > 1 else { return Hud.shared.flash("Can't close the only tab") }
        monitor.tabs.remove(at: tabIndex)
        monitor.tabIndex = min(tabIndex, tabs.count - 1)
        dedupe(monitor)
        layout()
        announceTab()
    }

    func switchTab(_ dir: Int) {
        guard tabs.count > 1 else { return Hud.shared.flash("Only one tab") }
        monitor.tabIndex = (tabIndex + dir + tabs.count) % tabs.count
        dedupe(monitor)
        layout()
        announceTab()
    }

    /// After `m` shows a different tab: panes showing a window that another display's visible tab
    /// already shows fall back through their history, so each window is in one place on screen.
    private func dedupe(_ m: Monitor) {
        let elsewhere = Set(monitors.filter { $0 !== m }.flatMap { $0.tab.panes.compactMap(\.current) })
        for pane in m.tab.panes where pane.current.map(elsewhere.contains) == true {
            fallback(pane, in: m.tab)
        }
    }

    private func announceTab() {
        let where_ = monitors.count > 1 ? " · display \(monitorIndex + 1)" : ""
        Hud.shared.flash("Tab \(tabIndex + 1) of \(tabs.count)\(where_)")
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        monitor.tabIndex = index
        dedupe(monitor)
        layout()
        announceTab()
    }
}

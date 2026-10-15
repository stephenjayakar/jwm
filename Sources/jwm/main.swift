import AppKit

func log(_ message: String) {
    guard ProcessInfo.processInfo.environment["JWM_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("jwm: \(message)\n".utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            begin()
        } else {
            print("jwm: waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility)")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self.begin()
            }
        }
        // Put parked windows back if we're killed from the terminal. SIGHUP is a restart (make restart):
        // windows stay where they are, and the next jwm adopts them as they are.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if sig == SIGHUP { WM.shared.keepWindowsOnQuit = true }
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func begin() {
        // Every AX call blocks until the app answers. The default timeout is 6 s, so one hung app
        // could freeze jwm; this caps every element, including windows, at 0.25 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        signal(SIGUSR1, SIG_IGN)
        usr1.setEventHandler { print(WM.shared.dump()); fflush(stdout) }
        usr1.resume()
        signalSources.append(usr1)
        let usr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        signal(SIGUSR2, SIG_IGN)
        usr2.setEventHandler { snapshotOwnWindows() }
        usr2.resume()
        signalSources.append(usr2)

        guard Hotkeys.shared.start() else {
            print("jwm: couldn't create the keyboard event tap")
            exit(1)
        }
        WM.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WM.shared.saveState()
        if !WM.shared.keepWindowsOnQuit { WM.shared.restoreAll() }
    }
}

let args = CommandLine.arguments
if args.contains("--list") || args.contains("--restore") {
    WM.shared.refresh()
    if args.contains("--restore") { WM.shared.restoreAll() }
    for window in WM.shared.windows.values.sorted(by: { $0.id < $1.id }) {
        print(window.id, window.label, window.element.frame.map { "\($0)" } ?? "?")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

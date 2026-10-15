import AppKit
import Carbon.HIToolbox

/// A named command, Emacs style. The table below drives ⌘D dispatch and the M-x palette.
struct Command {
    let name: String
    /// Key codes after the ⌘D prefix (modifiers are ignored, so ⌘D ⌘3 works like ⌘D 3).
    var keys: [Int] = []
    /// Bindings as shown in the palette.
    var binding = ""
    let help: String
    /// Hidden from the palette (meaningless to run from there).
    var unlisted = false
    let run: (WM) -> Void
}

extension WM {
    static let commands: [Command] = [
        Command(name: "split-window-right", keys: [kVK_ANSI_3], binding: "⌘D 3",
                help: "Split pane side by side") { $0.split(vertical: true) },
        Command(name: "split-window-below", keys: [kVK_ANSI_2], binding: "⌘D 2",
                help: "Split pane top / bottom") { $0.split(vertical: false) },
        Command(name: "delete-window", keys: [kVK_ANSI_0], binding: "⌘D 0",
                help: "Delete this pane") { $0.deletePane() },
        Command(name: "delete-other-windows", keys: [kVK_ANSI_1], binding: "⌘D 1",
                help: "Delete all other panes") { $0.deleteOtherPanes() },
        Command(name: "other-window", keys: [kVK_ANSI_O], binding: "⌘D o  ⌥Tab",
                help: "Select next pane (continues onto other displays)") { $0.focusPane(1) },
        Command(name: "previous-window", binding: "⌥⇧Tab",
                help: "Select previous pane (continues onto other displays)") { $0.focusPane(-1) },
        Command(name: "toggle-zoom", keys: [kVK_ANSI_F], binding: "⌘D f",
                help: "Full screen this pane, or put it back") { $0.toggleZoom() },
        Command(name: "enlarge-window", keys: [kVK_ANSI_Period], binding: "⌘D .",
                help: "Grow this pane") { $0.tab.resizeFocused(by: 0.05); $0.layout() },
        Command(name: "shrink-window", keys: [kVK_ANSI_Comma], binding: "⌘D ,",
                help: "Shrink this pane") { $0.tab.resizeFocused(by: -0.05); $0.layout() },
        Command(name: "move-window-to-next-display", keys: [kVK_ANSI_M], binding: "⌘D m",
                help: "Send this pane's window to the next display") { $0.sendToNextDisplay(1) },
        Command(name: "other-display", keys: [kVK_ANSI_N], binding: "⌘D n",
                help: "Select the next display, like Emacs other-frame") { $0.focusDisplay(1) },
        Command(name: "balance-windows", keys: [kVK_ANSI_Equal], binding: "⌘D =",
                help: "Give all panes equal space") { $0.tab.balance(); $0.layout() },

        Command(name: "switch-to-buffer", keys: [kVK_ANSI_B], binding: "⌘D b",
                help: "Pick a window to show in this pane") { $0.showBufferList() },
        Command(name: "previous-buffer", keys: [kVK_ANSI_J], binding: "⌘D j",
                help: "Back in this pane's history") { $0.walkHistory(-1) },
        Command(name: "next-buffer", keys: [kVK_ANSI_L], binding: "⌘D l",
                help: "Forward in this pane's history") { $0.walkHistory(1) },
        Command(name: "kill-buffer", keys: [kVK_ANSI_K], binding: "⌘D k",
                help: "Close this pane's window") { $0.killBuffer() },

        Command(name: "tab-new", keys: [kVK_ANSI_T], binding: "⌘D t",
                help: "New empty tab") { $0.newTab() },
        Command(name: "tab-close", keys: [kVK_ANSI_W], binding: "⌘D w",
                help: "Close this tab") { $0.closeTab() },
        Command(name: "tab-next", keys: [kVK_ANSI_RightBracket], binding: "⌘D ]",
                help: "Next tab") { $0.switchTab(1) },
        Command(name: "tab-previous", keys: [kVK_ANSI_LeftBracket], binding: "⌘D [",
                help: "Previous tab") { $0.switchTab(-1) },

        Command(name: "relayout", keys: [kVK_ANSI_R], binding: "⌘D r",
                help: "Re-scan windows and re-apply the layout") { $0.refresh(); $0.forceLayout() },
        Command(name: "reset-layout",
                help: "Forget all tabs and splits") { $0.resetLayout() },
        Command(name: "send-prefix", keys: [kVK_ANSI_D], binding: "⌘D ⌘D",
                help: "Send a real ⌘D to the app") { wm in
            // From the palette the app isn't focused yet; give it a moment.
            wm.focusSelected()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Hotkeys.shared.sendLiteralPrefix() }
        },
        Command(name: "quit-jwm",
                help: "Quit jwm and put all windows back") { _ in NSApp.terminate(nil) },

        Command(name: "execute-extended-command", keys: [kVK_ANSI_X, kVK_ANSI_Slash], binding: "⌘D x  ⌘D ?",
                help: "Run a command by name", unlisted: true) { $0.showPalette() },
        Command(name: "keyboard-quit", keys: [kVK_Escape, kVK_ANSI_G], binding: "⌘D Esc",
                help: "Cancel", unlisted: true) { _ in },
    ]
}

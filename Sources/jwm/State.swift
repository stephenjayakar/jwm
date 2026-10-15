import AppKit

/// What jwm remembers between runs. The layout is not saved: on start, jwm builds it from where the
/// windows are (see WM.adopt). Only learned minimum window sizes carry over.
/// Older state files also hold tabs and recency; the decoder ignores those keys.
struct SavedState: Codable {
    /// Learned minimum window sizes per app name.
    var minimums: [String: CGSize]?
}

extension WM {
    static let stateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/jwm/state.json")

    func saveState() {
        do {
            try FileManager.default.createDirectory(at: WM.stateURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(SavedState(minimums: minimums)).write(to: WM.stateURL, options: .atomic)
        } catch {
            log("couldn't save state: \(error)")
        }
    }

    /// Minimum window sizes learned in earlier runs.
    func loadMinimums() -> [String: CGSize] {
        guard let data = try? Data(contentsOf: WM.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return [:] }
        return state.minimums ?? [:]
    }
}

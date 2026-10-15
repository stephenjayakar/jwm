import CoreGraphics

class Node {
    weak var parent: Split?
    func collect(_ out: inout [Pane]) {}
}

/// A leaf of the split tree. Shows at most one window and remembers what it has shown.
final class Pane: Node {
    private(set) var history: [CGWindowID] = []
    private(set) var index = -1

    var current: CGWindowID? { history.indices.contains(index) ? history[index] : nil }

    override init() {}

    init(history: [CGWindowID], index: Int) {
        self.history = history
        self.index = min(max(index, -1), history.count - 1)
    }

    override func collect(_ out: inout [Pane]) { out.append(self) }

    /// Shows `id` right after the current entry; forward history is kept, not truncated.
    func show(_ id: CGWindowID) {
        if current == id { return }
        if let pos = history.firstIndex(of: id) {
            history.remove(at: pos)
            if pos < index { index -= 1 }
        }
        index += 1
        history.insert(id, at: index)
    }

    /// Moves to the nearest entry in direction `dir` (-1 back, +1 forward) that satisfies `ok`.
    @discardableResult
    func step(_ dir: Int, where ok: (CGWindowID) -> Bool) -> Bool {
        var i = index + dir
        while history.indices.contains(i) {
            if ok(history[i]) { index = i; return true }
            i += dir
        }
        return false
    }

    /// Forgets `id`. Returns true if it was the current entry (index then points at the previous one).
    func remove(_ id: CGWindowID) -> Bool {
        guard let pos = history.firstIndex(of: id) else { return false }
        history.remove(at: pos)
        if pos < index { index -= 1; return false }
        if pos == index { index -= 1; return true }
        return false
    }

    func clear() { index = -1 }
}

final class Split: Node {
    /// true: children side by side (Emacs C-x 3). false: stacked (C-x 2).
    let vertical: Bool
    var a: Node
    var b: Node
    var ratio: CGFloat = 0.5

    init(vertical: Bool, a: Node, b: Node) {
        self.vertical = vertical
        self.a = a
        self.b = b
    }

    override func collect(_ out: inout [Pane]) {
        a.collect(&out)
        b.collect(&out)
    }
}

/// A window configuration: a split tree plus which pane is selected.
final class Tab {
    var root: Node
    var focused: Pane
    var zoomed: Pane?
    /// UUID of the display this tab belonged to before that display disconnected. The tab goes back
    /// to it when it reconnects.
    var origin: String?

    init() {
        let pane = Pane()
        root = pane
        focused = pane
    }

    var panes: [Pane] {
        var out: [Pane] = []
        root.collect(&out)
        return out
    }

    var visiblePanes: [Pane] { zoomed.map { [$0] } ?? panes }

    func replace(_ old: Node, with new: Node) {
        if let parent = old.parent {
            if parent.a === old { parent.a = new } else { parent.b = new }
            new.parent = parent
        } else {
            root = new
            new.parent = nil
        }
    }

    func split(_ pane: Pane, vertical: Bool, with fresh: Pane) {
        let split = Split(vertical: vertical, a: pane, b: fresh)
        replace(pane, with: split)
        pane.parent = split
        fresh.parent = split
    }

    /// Removes `pane` from the tree; returns the pane that should take focus.
    func delete(_ pane: Pane) -> Pane? {
        guard let parent = pane.parent else { return nil }
        let sibling = parent.a === pane ? parent.b : parent.a
        replace(parent, with: sibling)
        var leaves: [Pane] = []
        sibling.collect(&leaves)
        return leaves.first
    }

    /// Calls `visit` with every node and its rect within `bounds`, in tree order. Splits honor
    /// `minimum` (each pane's smallest usable size) where the space allows, otherwise they share
    /// the space in proportion to the minimums.
    private func walk(in bounds: CGRect, minimum: (Pane) -> CGSize, _ visit: (Node, CGRect) -> Void) {
        func minSize(_ node: Node) -> CGSize {
            switch node {
            case let pane as Pane:
                return minimum(pane)
            case let split as Split:
                let a = minSize(split.a), b = minSize(split.b)
                return split.vertical
                    ? CGSize(width: a.width + b.width, height: max(a.height, b.height))
                    : CGSize(width: max(a.width, b.width), height: a.height + b.height)
            default:
                return .zero
            }
        }
        func divide(_ split: Split, _ length: CGFloat, _ minA: CGFloat, _ minB: CGFloat) -> CGFloat {
            let wanted = (length * split.ratio).rounded()
            guard minA + minB > 0 else { return wanted }
            if minA + minB > length { return (length * minA / (minA + minB)).rounded() }
            let clamped = min(max(wanted, minA), length - minB)
            // Store the ratio actually used, so growing/shrinking past a minimum has no dead zone.
            if clamped != wanted { split.ratio = clamped / length }
            return clamped
        }
        func walk(_ node: Node, _ r: CGRect) {
            visit(node, r)
            guard let split = node as? Split else { return }
            let minA = minSize(split.a), minB = minSize(split.b)
            if split.vertical {
                let w = divide(split, r.width, minA.width, minB.width)
                walk(split.a, CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
                walk(split.b, CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
            } else {
                let h = divide(split, r.height, minA.height, minB.height)
                walk(split.a, CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                walk(split.b, CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
            }
        }
        walk(root, bounds)
    }

    /// Pane rects within `bounds`, in tree order.
    func rects(in bounds: CGRect, minimum: (Pane) -> CGSize = { _ in .zero }) -> [(Pane, CGRect)] {
        if let zoomed { return [(zoomed, bounds)] }
        var out: [(Pane, CGRect)] = []
        walk(in: bounds, minimum: minimum) { node, r in
            if let pane = node as? Pane { out.append((pane, r)) }
        }
        return out
    }

    /// Something dragged edges of `pane`'s window from `expected` to `actual`: move the split boundaries
    /// to follow. `bounds` is what `rects(in:)` was given, `inset` how far windows sit inside their pane.
    func adjust(_ pane: Pane, from expected: CGRect, to actual: CGRect, bounds: CGRect, inset: CGFloat,
                minimum: (Pane) -> CGSize = { _ in .zero }) -> Bool {
        guard zoomed == nil else { return false }
        var splitRects: [ObjectIdentifier: CGRect] = [:]
        walk(in: bounds, minimum: minimum) { node, r in
            if node is Split { splitRects[ObjectIdentifier(node)] = r }
        }
        // Nearest ancestor split along that axis with the pane on the given side, and its new ratio.
        func boundary(vertical: Bool, paneInA: Bool, at position: CGFloat) -> (Split, CGFloat)? {
            var child: Node = pane
            while let parent = child.parent {
                if parent.vertical == vertical, (parent.a === child) == paneInA,
                   let r = splitRects[ObjectIdentifier(parent)] {
                    let ratio = vertical ? (position - r.minX) / r.width : (position - r.minY) / r.height
                    return (parent, min(0.9, max(0.1, ratio)))
                }
                child = parent
            }
            return nil
        }
        // Edges within a gap's width of where they were count as unchanged, so tools that ignore our
        // gaps (Raycast) still read as a one-edge resize. If both edges on an axis moved, the window was
        // moved rather than resized along that axis, which the tree can't express.
        let tolerance: CGFloat = 12
        let left = abs(actual.minX - expected.minX) > tolerance, right = abs(actual.maxX - expected.maxX) > tolerance
        let top = abs(actual.minY - expected.minY) > tolerance, bottom = abs(actual.maxY - expected.maxY) > tolerance
        if left && right || top && bottom { return false }
        let wanted = [
            right ? (true, true, actual.maxX + inset) : nil,
            left ? (true, false, actual.minX - inset) : nil,
            bottom ? (false, true, actual.maxY + inset) : nil,
            top ? (false, false, actual.minY - inset) : nil,
        ].compactMap { $0 }
        // All or nothing: half-applying e.g. Raycast "top half" on a full-height pane would be surprising.
        let moves = wanted.compactMap { boundary(vertical: $0.0, paneInA: $0.1, at: $0.2) }
        guard !moves.isEmpty, moves.count == wanted.count else { return false }
        for (split, ratio) in moves { split.ratio = ratio }
        return true
    }

    /// Moves `pane` to one side of the whole tab (Raycast "left half" and similar), taking `ratio` of it.
    /// `vertical`: left/right (true) or top/bottom (false). `first`: left or top.
    /// The rest of the tree keeps its shape on the other side. A pane outside the tree (new) docks next
    /// to the whole tree. A lone root pane gets `partner` next to it.
    func dock(_ pane: Pane, vertical: Bool, first: Bool, ratio: CGFloat, partner: () -> Pane) {
        zoomed = nil
        let rest: Node
        if pane.parent != nil {
            _ = delete(pane)
            rest = root
        } else if pane !== root {
            rest = root
        } else {
            rest = partner()
        }
        let split = first ? Split(vertical: vertical, a: pane, b: rest) : Split(vertical: vertical, a: rest, b: pane)
        let r = min(0.9, max(0.1, ratio))
        split.ratio = first ? r : 1 - r
        root = split
        split.parent = nil
        pane.parent = split
        rest.parent = split
        focused = pane
    }

    /// Grows (positive) or shrinks the focused pane within its parent split.
    func resizeFocused(by delta: CGFloat) {
        guard let parent = focused.parent else { return }
        let sign: CGFloat = parent.a === focused ? 1 : -1
        parent.ratio = min(0.9, max(0.1, parent.ratio + sign * delta))
    }

    /// Like Emacs balance-windows: panes along each axis get equal space.
    func balance() {
        func weight(_ node: Node, vertical: Bool) -> CGFloat {
            guard let split = node as? Split else { return 1 }
            let a = weight(split.a, vertical: vertical), b = weight(split.b, vertical: vertical)
            return split.vertical == vertical ? a + b : max(a, b)
        }
        func walk(_ node: Node) {
            guard let split = node as? Split else { return }
            let a = weight(split.a, vertical: split.vertical), b = weight(split.b, vertical: split.vertical)
            split.ratio = a / (a + b)
            walk(split.a)
            walk(split.b)
        }
        walk(root)
    }
}

/// Builds a split tree that matches where windows already are, so starting jwm moves them as
/// little as possible. `windows` is front to back. Recursively finds a vertical or horizontal
/// line that no window crosses (within `tolerance`) and splits there. When windows overlap so
/// that no such line exists, the backmost one is dropped. Returns nil for no windows.
func inferLayout(_ windows: [(id: CGWindowID, frame: CGRect)], in region: CGRect, tolerance: CGFloat) -> Node? {
    guard let front = windows.first else { return nil }
    if windows.count == 1 {
        let pane = Pane()
        pane.show(front.id)
        return pane
    }
    struct Cut { let vertical: Bool; let at: CGFloat; let a: [Int]; let b: [Int]; let overlap: CGFloat }
    var best: Cut?
    for vertical in [true, false] {
        let lo = { (r: CGRect) in vertical ? r.minX : r.minY }
        let hi = { (r: CGRect) in vertical ? r.maxX : r.maxY }
        let order = windows.indices.sorted { lo(windows[$0].frame) + hi(windows[$0].frame) < lo(windows[$1].frame) + hi(windows[$1].frame) }
        for k in 1..<order.count {
            let a = Array(order[..<k]), b = Array(order[k...])
            let aEnd = a.map { hi(windows[$0].frame) }.max()!, bStart = b.map { lo(windows[$0].frame) }.min()!
            let overlap = aEnd - bStart
            guard overlap <= tolerance, best == nil || overlap < best!.overlap else { continue }
            best = Cut(vertical: vertical, at: (aEnd + bStart) / 2, a: a, b: b, overlap: overlap)
        }
    }
    guard let cut = best else {
        return inferLayout(Array(windows.dropLast()), in: region, tolerance: tolerance)
    }
    let length = cut.vertical ? region.width : region.height
    let start = cut.vertical ? region.minX : region.minY
    let ratio = min(0.9, max(0.1, (cut.at - start) / max(1, length)))
    let first = cut.vertical
        ? CGRect(x: region.minX, y: region.minY, width: length * ratio, height: region.height)
        : CGRect(x: region.minX, y: region.minY, width: region.width, height: length * ratio)
    let second = cut.vertical
        ? CGRect(x: first.maxX, y: region.minY, width: region.width - first.width, height: region.height)
        : CGRect(x: region.minX, y: first.maxY, width: region.width, height: region.height - first.height)
    // Keep front-to-back order inside each side, so overlap drops still pick the backmost window.
    let side = { (idx: [Int]) in idx.sorted().map { windows[$0] } }
    guard let a = inferLayout(side(cut.a), in: first, tolerance: tolerance),
          let b = inferLayout(side(cut.b), in: second, tolerance: tolerance) else { return nil }
    let split = Split(vertical: cut.vertical, a: a, b: b)
    split.ratio = ratio
    a.parent = split
    b.parent = split
    return split
}

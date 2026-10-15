import AppKit

struct PickerItem {
    var icon: NSImage?
    var title: String
    var titleFont: NSFont = .systemFont(ofSize: 14)
    /// Secondary text after the title.
    var subtitle: String?
    /// Right-aligned text (app name, key binding).
    var detail: String
    var detailFont: NSFont = .systemFont(ofSize: 12)
    var dimmed = false
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Minibuffer-style chooser: a search field over a list. ↑↓ move, Enter picks, Esc cancels,
/// Tab completes (if `complete` is set). Used by the buffer list and the command palette.
final class Picker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    /// Tab completion: returns the new query, or nil to leave it.
    var complete: ((String) -> String?)?

    private let panel = KeyPanel(contentRect: CGRect(x: 0, y: 0, width: 680, height: 440),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = NSTableView()
    private var items: [PickerItem] = []
    private var filter: (String) -> [Int] = { _ in [] }
    /// Indices into `items`, in display order.
    private var shown: [Int] = []
    private var completion: ((Int?) -> Void)?

    init(placeholder: String, monospaced: Bool = false) {
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.delegate = self

        field.placeholderString = placeholder
        field.font = monospaced ? .monospacedSystemFont(ofSize: 17, weight: .regular) : .systemFont(ofSize: 18)
        field.focusRingType = .none
        field.isBezeled = false
        field.drawsBackground = false
        field.delegate = self

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 32
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pickSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSView()
        for view in [field, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        panel.contentView = content
    }

    /// `filter` maps the query to indices of `items` in display order.
    func show(_ items: [PickerItem], filter: @escaping (String) -> [Int], completion: @escaping (Int?) -> Void) {
        self.items = items
        self.filter = filter
        self.completion = completion
        field.stringValue = ""
        refilter()
        if let screen = WM.shared.currentScreen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.6 - size.height / 2))
        } else {
            panel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func refilter() {
        shown = filter(field.stringValue)
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func finish(_ index: Int?) {
        guard let completion else { return }
        self.completion = nil
        panel.orderOut(nil)
        completion(index)
    }

    @objc private func pickSelected() {
        let row = table.selectedRow
        finish(shown.indices.contains(row) ? shown[row] : nil)
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): pickSelected()
        case #selector(NSResponder.cancelOperation(_:)): finish(nil)
        case #selector(NSResponder.insertTab(_:)):
            if let completed = complete?(field.stringValue), completed != field.stringValue {
                field.stringValue = completed
                textView.moveToEndOfDocument(nil)
                refilter()
            }
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) { finish(nil) }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[shown[row]]
        var views: [NSView] = []
        if let image = item.icon {
            let icon = NSImageView(image: image)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 20),
                                         icon.heightAnchor.constraint(equalToConstant: 20)])
            views.append(icon)
        }
        let title = NSTextField(labelWithString: item.title)
        title.font = item.titleFont
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        views.append(title)
        if let subtitle = item.subtitle {
            let label = NSTextField(labelWithString: subtitle)
            label.font = .systemFont(ofSize: 12.5)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(label)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        views.append(spacer)
        let detail = NSTextField(labelWithString: item.detail)
        detail.font = item.detailFont
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        views.append(detail)

        let rowView = NSStackView(views: views)
        rowView.spacing = 10
        rowView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        if item.dimmed { rowView.alphaValue = 0.6 }
        return rowView
    }
}

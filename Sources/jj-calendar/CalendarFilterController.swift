import AppKit

/// 日历筛选面板 (popover): 复选框可连续勾选, 面板不关闭; 「仅」按钮 / ⌥ 点击某日历 = 只显示它.
final class CalendarFilterController: NSViewController {
    var onChange: ((Set<String>) -> Void)?

    private var calendars: [CalendarSummary] = []
    private var hidden: Set<String> = []
    private var checkboxes: [NSButton] = []
    private let stack = NSStackView()

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        view = stack
    }

    func update(calendars: [CalendarSummary], hidden: Set<String>) {
        self.hidden = hidden
        let ids = calendars.map(\.id)
        if ids != self.calendars.map(\.id) || !isViewLoaded {
            self.calendars = calendars
            rebuild()
        } else {
            syncStates()
        }
    }

    private func rebuild() {
        _ = view
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        checkboxes = []
        let showAll = NSButton(title: "全部显示", target: self, action: #selector(showAll))
        let hideAll = NSButton(title: "全部隐藏", target: self, action: #selector(hideAll))
        for button in [showAll, hideAll] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        showAll.setAccessibilityIdentifier("calendarsShowAll")
        hideAll.setAccessibilityIdentifier("calendarsHideAll")
        stack.addArrangedSubview(NSStackView(views: [showAll, hideAll]))

        let grouped = Dictionary(grouping: calendars, by: \.source).sorted { $0.key < $1.key }
        for (source, items) in grouped {
            let header = NSTextField(labelWithString: source.isEmpty ? "其他" : source)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(1, after: header)
            for summary in items.sorted(by: { $0.title < $1.title }) {
                let checkbox = NSButton(checkboxWithTitle: summary.title, target: self, action: #selector(toggle(_:)))
                let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: summary.color.color])
                let name = NSAttributedString(string: summary.title, attributes: [.foregroundColor: NSColor.labelColor])
                title.append(name)
                checkbox.attributedTitle = title
                checkbox.identifier = NSUserInterfaceItemIdentifier(summary.id)
                checkbox.setAccessibilityLabel(summary.title)
                checkbox.toolTip = "⌥ 点击: 只显示此日历"
                checkboxes.append(checkbox)
                let only = NSButton(title: "仅", target: self, action: #selector(showOnlyButton(_:)))
                only.bezelStyle = .inline
                only.controlSize = .mini
                only.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
                only.identifier = checkbox.identifier
                only.toolTip = "只显示此日历"
                only.setAccessibilityLabel("只显示 \(summary.title)")
                let row = NSStackView(views: [checkbox, only])
                row.spacing = 4
                stack.addArrangedSubview(row)
            }
        }
        syncStates()
    }

    private func syncStates() {
        for checkbox in checkboxes {
            checkbox.state = hidden.contains(checkbox.identifier?.rawValue ?? "") ? .off : .on
        }
    }

    @objc
    private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if NSEvent.modifierFlags.contains(.option) {
            showOnly(id)
            return
        }
        if hidden.remove(id) == nil {
            hidden.insert(id)
        }
        commit()
    }

    @objc
    private func showOnlyButton(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        showOnly(id)
    }

    private func showOnly(_ id: String) {
        hidden = Set(calendars.map(\.id)).subtracting([id])
        commit()
    }

    @objc
    private func showAll() {
        hidden = []
        commit()
    }

    @objc
    private func hideAll() {
        hidden = Set(calendars.map(\.id))
        commit()
    }

    private func commit() {
        syncStates()
        onChange?(hidden)
    }
}

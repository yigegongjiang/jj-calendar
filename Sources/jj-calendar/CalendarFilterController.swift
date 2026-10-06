import AppKit

/// 日历筛选面板 (popover): 复选框可连续勾选, 面板不关闭; 「仅」按钮 / ⌥ 点击某日历 = 只显示它.
final class CalendarFilterController: NSViewController {
    var onChange: ((Set<String>) -> Void)?

    private var calendars: [CalendarSummary] = []
    private var hidden: Set<String> = []
    private var checkboxes: [NSButton] = []
    private var grid: NSGridView?
    private let font = NSFont.systemFont(ofSize: 12)
    private let smallFont = NSFont.systemFont(ofSize: 11)

    override func loadView() {
        view = NSView()
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
        grid?.removeFromSuperview()
        checkboxes = []
        let showAll = textButton("全部显示", action: #selector(showAll))
        let hideAll = textButton("全部隐藏", action: #selector(hideAll))
        showAll.setAccessibilityIdentifier("calendarsShowAll")
        hideAll.setAccessibilityIdentifier("calendarsHideAll")
        let actions = NSStackView(views: [showAll, hideAll])
        actions.spacing = 12

        // 两列 grid 四边钉死 (popover 尺寸 = grid fittingSize): 复选框左对齐, 「仅」统一贴右, 长标题截断不撑歪布局.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 3
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .trailing
        grid.addRow(with: [actions, NSGridCell.emptyContentView]).mergeCells(in: NSRange(location: 0, length: 2))
        let grouped = Dictionary(grouping: calendars, by: \.source).sorted { $0.key < $1.key }
        for (index, (source, items)) in grouped.enumerated() {
            let header = NSTextField(labelWithString: source.isEmpty ? "其他" : source)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .tertiaryLabelColor
            header.lineBreakMode = .byTruncatingTail
            let headerRow = grid.addRow(with: [header, NSGridCell.emptyContentView])
            headerRow.mergeCells(in: NSRange(location: 0, length: 2))
            headerRow.topPadding = index == 0 ? 4 : 6
            for summary in items.sorted(by: { $0.title < $1.title }) {
                grid.addRow(with: calendarRow(summary))
            }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10)
        ])
        self.grid = grid
        syncStates()
    }

    private func calendarRow(_ summary: CalendarSummary) -> [NSView] {
        let checkbox = NSButton(checkboxWithTitle: summary.title, target: self, action: #selector(toggle(_:)))
        checkbox.font = font
        checkbox.image = Self.box(summary.color.color, checked: false)
        checkbox.alternateImage = Self.box(summary.color.color, checked: true)
        checkbox.imageHugsTitle = true
        checkbox.lineBreakMode = .byTruncatingTail
        checkbox.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        checkbox.identifier = NSUserInterfaceItemIdentifier(summary.id)
        checkbox.setAccessibilityLabel(summary.title)
        checkbox.toolTip = "\(summary.title)\n⌥ 点击: 只显示此日历"
        checkboxes.append(checkbox)
        let only = textButton("仅", action: #selector(showOnlyButton(_:)))
        only.identifier = checkbox.identifier
        only.toolTip = "只显示此日历"
        only.setAccessibilityLabel("只显示 \(summary.title)")
        return [checkbox, only]
    }

    private func textButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = smallFont
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    /// 日历色圆角方框: 勾选 = 实心 + 对勾 (按底色亮度取黑 / 白), 未勾选 = 描边.
    private static func box(_ color: NSColor, checked: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3.5, yRadius: 3.5)
            guard checked else {
                color.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                return true
            }
            color.setFill()
            path.fill()
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
                .applying(.init(paletteColors: [luminance > 0.6 ? .black : .white]))
            if let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let origin = NSPoint(x: (size.width - mark.size.width) / 2, y: (size.height - mark.size.height) / 2)
                mark.draw(in: NSRect(origin: origin, size: mark.size))
            }
            return true
        }
    }

    private func syncStates() {
        for checkbox in checkboxes {
            let isOn = !hidden.contains(checkbox.identifier?.rawValue ?? "")
            checkbox.state = isOn ? .on : .off
            checkbox.attributedTitle = NSAttributedString(string: checkbox.title, attributes: [
                .font: font,
                .foregroundColor: isOn ? NSColor.labelColor : NSColor.secondaryLabelColor
            ])
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

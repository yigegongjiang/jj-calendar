import AppKit

/// 日历筛选面板 (popover): 复选框可连续勾选, 面板不关闭; 「只显示」按钮 / ⌥ 点击某日历 = 只显示它.
/// 已忽略的日历: 置底淡化, 全部显示 / 全部隐藏 / 只显示 均不改动其勾选状态.
final class CalendarFilterController: NSViewController {
    var onChange: ((_ hidden: Set<String>, _ ignored: Set<String>) -> Void)?

    private var calendars: [CalendarSummary] = []
    private var hidden: Set<String> = []
    private var ignored: Set<String> = []
    private var checkboxes: [NSButton] = []
    private var grid: NSGridView?
    private let font = NSFont.systemFont(ofSize: 12)

    override func loadView() {
        view = NSView()
    }

    func update(calendars: [CalendarSummary], hidden: Set<String>, ignored: Set<String>) {
        self.hidden = hidden
        let ids = calendars.map(\.id)
        if ids != self.calendars.map(\.id) || ignored != self.ignored || !isViewLoaded {
            self.calendars = calendars
            self.ignored = ignored
            rebuild()
        } else {
            syncStates()
        }
    }

    private func rebuild() {
        _ = view
        grid?.removeFromSuperview()
        checkboxes = []
        let showAll = pushButton("全部显示", size: .small, action: #selector(showAll))
        let hideAll = pushButton("全部隐藏", size: .small, action: #selector(hideAll))
        showAll.setAccessibilityIdentifier("calendarsShowAll")
        hideAll.setAccessibilityIdentifier("calendarsHideAll")
        let actions = NSStackView(views: [showAll, hideAll])
        actions.spacing = 6

        // 三列 grid 四边钉死 (popover 尺寸 = grid fittingSize): 复选框左对齐, 按钮统一贴右, 长标题截断不撑歪布局.
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 3
        grid.columnSpacing = 6
        grid.column(at: 0).trailingPadding = 4
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 2).xPlacement = .trailing
        addMergedRow(actions, to: grid, topPadding: 0)
        let active = calendars.filter { !ignored.contains($0.id) }
        let grouped = Dictionary(grouping: active, by: \.source).sorted { $0.key < $1.key }
        for (source, items) in grouped {
            addMergedRow(header(source.isEmpty ? "其他" : source), to: grid, topPadding: 6)
            for summary in items.sorted(by: { $0.title < $1.title }) {
                grid.addRow(with: calendarRow(summary))
            }
        }
        let ignoredItems = calendars.filter { ignored.contains($0.id) }.sorted { $0.title < $1.title }
        if !ignoredItems.isEmpty {
            addMergedRow(header("已忽略 (不参与全部显示 / 隐藏)"), to: grid, topPadding: 10)
            for summary in ignoredItems {
                // 「取消忽略」横跨两列按钮, 避免撑宽「忽略」列.
                let row = grid.addRow(with: calendarRow(summary))
                row.mergeCells(in: NSRange(location: 1, length: 2))
                row.cell(at: 1).xPlacement = .trailing
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

    private func addMergedRow(_ view: NSView, to grid: NSGridView, topPadding: CGFloat) {
        let row = grid.addRow(with: [view, NSGridCell.emptyContentView, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 3))
        row.topPadding = topPadding
    }

    private func header(_ title: String) -> NSTextField {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        return header
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
        if ignored.contains(summary.id) {
            // 淡化整行: 视觉上不再吸引注意, 仍可单独勾选.
            checkbox.alphaValue = 0.45
            let restore = pushButton("取消忽略", size: .mini, action: #selector(toggleIgnored(_:)))
            restore.identifier = checkbox.identifier
            restore.setAccessibilityLabel("取消忽略 \(summary.title)")
            return [checkbox, restore, NSGridCell.emptyContentView]
        }
        let only = pushButton("只显示", size: .mini, action: #selector(showOnlyButton(_:)))
        only.identifier = checkbox.identifier
        only.toolTip = "只显示此日历"
        only.setAccessibilityLabel("只显示 \(summary.title)")
        let ignore = pushButton("忽略", size: .mini, action: #selector(toggleIgnored(_:)))
        ignore.identifier = checkbox.identifier
        ignore.toolTip = "移到「已忽略」: 淡化显示, 不参与全部显示 / 隐藏"
        ignore.setAccessibilityLabel("忽略 \(summary.title)")
        return [checkbox, only, ignore]
    }

    /// 标准圆角按钮 (有边框 = 一眼可认出可点击).
    private func pushButton(_ title: String, size: NSControl.ControlSize, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .push
        button.controlSize = size
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
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

    @objc
    private func toggleIgnored(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if ignored.remove(id) == nil {
            ignored.insert(id)
        }
        rebuild()
        onChange?(hidden, ignored)
    }

    /// 批量操作只作用于未忽略的日历; 已忽略的保持原状态.
    private var activeIDs: Set<String> {
        Set(calendars.map(\.id)).subtracting(ignored)
    }

    private func showOnly(_ id: String) {
        hidden = hidden.intersection(ignored).union(activeIDs.subtracting([id]))
        commit()
    }

    @objc
    private func showAll() {
        hidden.subtract(activeIDs)
        commit()
    }

    @objc
    private func hideAll() {
        hidden.formUnion(activeIDs)
        commit()
    }

    private func commit() {
        syncStates()
        onChange?(hidden, ignored)
    }
}

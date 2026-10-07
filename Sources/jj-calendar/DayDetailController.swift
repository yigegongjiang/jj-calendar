import AppKit

/// 当日完整列表 (popover 内容): 全部日程 / 提醒; 文本可选中复制 (如账号); 超高时滚动.
/// 可写条目: 「编辑」-> 编辑器; 提醒勾选框 = 完成 / 取消完成; 表头「+日程 / +提醒」新建于当日.
final class DayDetailController: NSViewController {
    private static let width: CGFloat = 340
    private static let maxHeight: CGFloat = 520
    private static let inset: CGFloat = 12
    private static let markerWidth: CGFloat = 14
    private static let editWidth: CGFloat = 40

    var onEdit: ((CalendarEvent) -> Void)?
    var onCreate: ((_ isReminder: Bool) -> Void)?
    var onToggleCompleted: ((CalendarEvent, Bool) async throws -> Void)?

    /// 当前展示的日期 (再次点击同日 = 关闭; 数据刷新时据此定位).
    private(set) var date: Date?
    private let stack = NSStackView()
    private let document = FlippedView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: Self.inset, bottom: 12, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width)
        ])
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("dayDetail")
        view = scrollView
    }

    func update(day: DayInfo, items: [CalendarEvent], calendar: Calendar) {
        _ = view
        date = day.date
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let today = day.isToday ? " · 今天" : ""
        let header = NSTextField(labelWithString: "\(day.year)年\(EventText.day(day.date))\(today) · \(items.count) 项")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let newEvent = smallButton("+日程", id: "dayNewEvent") { $0.onCreate?(false) }
        let newReminder = smallButton("+提醒", id: "dayNewReminder") { $0.onCreate?(true) }
        let headerRow = NSStackView(views: [header, NSView(), newEvent, newReminder])
        headerRow.spacing = 4
        headerRow.widthAnchor.constraint(equalToConstant: Self.width - Self.inset * 2).isActive = true
        stack.addArrangedSubview(headerRow)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.preferredMaxLayoutWidth = Self.width - Self.inset * 2
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        if items.isEmpty {
            stack.addArrangedSubview(secondaryLabel("无日程"))
        }
        for event in items {
            stack.addArrangedSubview(itemRow(event, calendar: calendar))
        }
        view.setAccessibilityLabel(header.stringValue)
        resize()
    }

    private func resize() {
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        preferredContentSize = NSSize(width: Self.width, height: min(height, Self.maxHeight))
    }

    private func showError(_ text: String) {
        errorLabel.stringValue = text
        errorLabel.isHidden = false
        resize()
    }

    /// 回调经 weak self 分发.
    private func smallButton(
        _ title: String, id: String, _ action: @escaping (DayDetailController) -> Void
    ) -> NSButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = .mini
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        button.setAccessibilityIdentifier(id)
        button.handler = { [weak self] in
            if let self {
                action(self)
            }
        }
        return button
    }

    private func toggleCompleted(_ checkbox: NSButton, item: CalendarEvent) {
        let done = checkbox.state == .on
        checkbox.isEnabled = false
        Task {
            do {
                // 成功后由数据刷新重建列表.
                try await onToggleCompleted?(item, done)
            } catch {
                checkbox.state = done ? .off : .on
                checkbox.isEnabled = true
                showError(error.localizedDescription)
            }
        }
    }

    /// 标记 (可写提醒 = 勾选框) + [时间 标题 / 日历 · 状态 · 地点] + 「编辑」(可写).
    private func itemRow(_ event: CalendarEvent, calendar: Calendar) -> NSView {
        let isOverdue = event.isOverdue
        let when = NSAttributedString(string: EventText.when(event, calendar: calendar) + "  ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isOverdue ? NSColor.systemRed : NSColor.secondaryLabelColor
        ])
        var titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ]
        if event.isCompleted {
            titleAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            titleAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        let line = NSMutableAttributedString(attributedString: when)
        line.append(NSAttributedString(string: event.title, attributes: titleAttributes))
        let title = NSTextField(labelWithAttributedString: line)
        configureWrapping(title)

        let state = event.isCompleted ? "已完成" : isOverdue ? "逾期" : nil
        let source = event.isReminder ? "提醒事项 · \(event.calendarTitle)" : event.calendarTitle
        let detail = secondaryLabel([source, state, event.location].compactMap(\.self).joined(separator: " · "))
        configureWrapping(detail)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let marker = markerView(event)
        marker.widthAnchor.constraint(equalToConstant: Self.markerWidth).isActive = true
        var views = [marker, text]
        if event.isWritable {
            let edit = smallButton("编辑", id: "dayItemEdit") { $0.onEdit?(event) }
            edit.setAccessibilityLabel("编辑: \(event.title)")
            edit.widthAnchor.constraint(equalToConstant: Self.editWidth).isActive = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            views += [spacer, edit]
        }
        let row = NSStackView(views: views)
        row.alignment = .top
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: Self.width - Self.inset * 2).isActive = true
        row.alphaValue = event.isIgnored ? 0.5 : 1
        return row
    }

    /// 可写提醒 = 勾选框 (完成 / 取消完成); 其余 = 颜色标记.
    private func markerView(_ event: CalendarEvent) -> NSView {
        guard event.isReminder, event.isWritable else {
            let image = NSImageView(image: Self.marker(event))
            image.setAccessibilityElement(false)
            return image
        }
        let checkbox = ClosureButton(checkboxWithTitle: "", target: nil, action: nil)
        checkbox.controlSize = .small
        checkbox.state = event.isCompleted ? .on : .off
        checkbox.setAccessibilityLabel("完成: \(event.title)")
        checkbox.setAccessibilityIdentifier("dayItemDone")
        checkbox.handler = { [weak self, weak checkbox] in
            if let self, let checkbox {
                toggleCompleted(checkbox, item: event)
            }
        }
        return checkbox
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 多行换行 + 可选中复制.
    private func configureWrapping(_ label: NSTextField) {
        label.isSelectable = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Self.width - Self.inset * 2 - Self.markerWidth - 6 - Self.editWidth - 6
    }

    /// 日程 = 日历色竖条; 提醒 = 勾选圈 (已完成实心).
    private static func marker(_ event: CalendarEvent) -> NSImage {
        let color = event.color.color
        return NSImage(size: NSSize(width: markerWidth, height: 15), flipped: true) { _ in
            if event.isReminder {
                let circle = NSBezierPath(ovalIn: NSRect(x: 1, y: 3, width: 8, height: 8))
                if event.isCompleted {
                    color.setFill()
                    circle.fill()
                } else {
                    color.setStroke()
                    circle.lineWidth = 1.2
                    circle.stroke()
                }
            } else {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 4, height: 13), xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
    }
}

/// 按下 (含 AX press) 调用 handler; 创建方以 weak 捕获所属控制器.
final class ClosureButton: NSButton {
    var handler: (() -> Void)? {
        didSet {
            target = self
            action = #selector(fire)
        }
    }

    @objc
    private func fire() {
        handler?()
    }
}

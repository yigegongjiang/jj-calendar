import AppKit

/// 日期格: 月份底色微弱交替 (可关) + 日期号 (1 日强调色实心标签「yyyy-MM-dd」); 星期见表头; 折叠数见同列「+N 项」.
final class DayCellView: NSView {
    private var info: DayInfo?
    private var fontSize = Typography.standard
    private var monthTint = true
    var drawsLeadingEdge = false
    /// AX 按下 = 打开当日列表.
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    func configure(_ info: DayInfo, eventCount: Int, hidden: Int, config: WeekRowView.Config) {
        self.info = info
        fontSize = config.typography.fontSize
        monthTint = config.monthTint
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let suffix = info.isToday ? " 今天" : ""
        let folded = hidden == 0 ? "" : ", 另有 \(hidden) 个未显示"
        setAccessibilityLabel("\(info.year)年\(EventText.day(info.date))\(suffix), \(eventCount) 个日程\(folded)")
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func draw(_: NSRect) {
        guard let info else { return }
        let background: NSColor = if monthTint, info.month.isMultiple(of: 2) {
            NSColor.controlBackgroundColor.blended(withFraction: 0.025, of: .labelColor) ?? .controlBackgroundColor
        } else {
            .controlBackgroundColor
        }
        background.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        if drawsLeadingEdge {
            NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }

        let isWeekend = info.weekday == 1 || info.weekday == 7
        let isFirst = info.day == 1
        // 1 日: 实心强调色标签, yyyy-MM-dd (带年份便于跨年辨认).
        let text = isFirst ? String(format: "%04d-%02d-01", info.year, info.month) : "\(info.day)"
        let color: NSColor = info.isToday || isFirst ? .white
            : info.isPast ? .secondaryLabelColor
            : isWeekend ? .secondaryLabelColor : .labelColor
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: fontSize - 0.5, weight: info.day == 1 || info.isToday ? .bold : .regular
            ),
            .foregroundColor: color
        ])
        let size = label.size()
        let origin = NSPoint(x: 4, y: 1)
        if info.isToday || isFirst {
            (info.isToday ? NSColor.systemRed : Self.monthColor).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: origin.x - 3, y: origin.y, width: size.width + 6, height: size.height),
                xRadius: size.height / 2, yRadius: size.height / 2
            ).fill()
        }
        label.draw(at: origin)
    }

    /// 1 日标签底色.
    private static let monthColor = NSColor.controlAccentColor
}

/// 列折叠提示「+N 项」: 强调色; 点击 (经响应链到 WeekRowView) / AX 按下 -> 当日完整列表; 悬停列出未显示条目.
final class MoreChipView: NSView {
    var onPress: (() -> Void)?
    private let text: NSAttributedString

    init(hidden: [CalendarEvent], typography: Typography, calendar: Calendar) {
        text = NSAttributedString(string: "+\(hidden.count) 项", attributes: [
            .font: NSFont.systemFont(ofSize: typography.fontSize - 0.5, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor
        ])
        super.init(frame: .zero)
        toolTip = "另有 \(hidden.count) 项, 点击查看当日全部\n" + hidden.map {
            EventText.detail($0, calendar: calendar).replacingOccurrences(of: "\n", with: " · ")
        }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("另有 \(hidden.count) 项未显示, 查看当日全部")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }

    override func draw(_: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let height = text.size().height
        text.draw(in: NSRect(x: 5, y: (bounds.height - height) / 2, width: bounds.width - 6, height: height))
    }
}

/// 当日完整列表 (popover 内容): 全部日程 / 提醒, 只读; 文本可选中复制 (如账号); 超高时滚动.
final class DayDetailController: NSViewController {
    private static let width: CGFloat = 340
    private static let maxHeight: CGFloat = 520
    private static let inset: CGFloat = 12
    private static let markerWidth: CGFloat = 10

    /// 当前展示的日期 (再次点击同日 = 关闭; 数据刷新时据此定位).
    private(set) var date: Date?
    private let stack = NSStackView()
    private let document = FlippedView()

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
        stack.addArrangedSubview(header)
        if items.isEmpty {
            stack.addArrangedSubview(secondaryLabel("无日程"))
        }
        let now = Date()
        for event in items {
            stack.addArrangedSubview(itemRow(event, calendar: calendar, now: now))
        }
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        document.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        preferredContentSize = NSSize(width: Self.width, height: min(height, Self.maxHeight))
        view.setAccessibilityLabel(header.stringValue)
    }

    /// 标记 + [时间 标题 / 日历 · 状态 · 地点].
    private func itemRow(_ event: CalendarEvent, calendar: Calendar, now: Date) -> NSView {
        let isOverdue = event.isOverdue(now: now)
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
        let marker = NSImageView(image: Self.marker(event))
        marker.setAccessibilityElement(false)
        let row = NSStackView(views: [marker, text])
        row.alignment = .top
        row.spacing = 6
        row.alphaValue = event.isIgnored ? 0.5 : 1
        return row
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
        label.preferredMaxLayoutWidth = Self.width - Self.inset * 2 - Self.markerWidth - 6
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

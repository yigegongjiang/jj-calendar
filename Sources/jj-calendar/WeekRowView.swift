import AppKit

/// 一行: 日期格 (DayCellView; ≤ 7 / 14 个, 区间首日前、末日后留空) + 事件 chip.
/// 容量不足的列: 末行改为「+N 项」; 点击日期格 / chip / +N -> 当日完整列表 (onSelectDay).
final class WeekRowView: NSView {
    struct Config: Equatable {
        let typography: Typography
        let capacity: Int
        let monthTint: Bool
    }

    private struct Slot {
        let chip: NSView
        let startCol: Int
        let endCol: Int
        let line: Int
    }

    /// 点击 / AX 按下某列 -> 由 WeekGridView 弹出当日列表, 锚定该日期格.
    var onSelectDay: ((_ col: Int, _ anchor: NSView) -> Void)?

    private var row: WeekRow?
    private var config: Config?
    private var calendar: Calendar?
    private var dayViews: [DayCellView] = []
    private var slots: [Slot] = []
    /// 本行折叠 (未显示) 的日程格次数.
    private(set) var hiddenTotal = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    /// 内容 / 行高 / 容量变化时才重建 chip (数据刷新时未变的行不重建); 仅尺寸变化走 layout().
    func apply(_ config: Config, row: WeekRow, calendar: Calendar) {
        guard config != self.config || row != self.row || calendar != self.calendar else { return }
        self.config = config
        self.row = row
        self.calendar = calendar
        let capacity = config.capacity

        syncDayViews(count: row.days.count)
        slots.forEach { $0.chip.removeFromSuperview() }
        slots = []
        // 每列独立: 超出容量 -> 可见行数 = 容量 - 1, 末行留给「+N 项」.
        let visible = row.days.indices.map { col in
            row.lanesPerColumn[col] + row.timed[col].count > capacity ? max(0, capacity - 1) : capacity
        }
        var hidden = Array(repeating: [CalendarEvent](), count: row.days.count)
        placeBars(row.bars, visible: visible, hidden: &hidden, typography: config.typography, calendar: calendar)
        for (col, events) in row.timed.enumerated() {
            for (offset, event) in events.enumerated() {
                let line = row.lanesPerColumn[col] + offset
                guard line < visible[col] else {
                    hidden[col].append(event)
                    continue
                }
                let chip = EventChipView(
                    event: event, style: .timed, dimmed: row.days[col].isPast,
                    typography: config.typography, calendar: calendar
                )
                chip.onPress = { [weak self] in self?.select(col) }
                slots.append(Slot(chip: chip, startCol: col, endCol: col, line: line))
            }
        }
        for col in row.days.indices where !hidden[col].isEmpty && visible[col] < capacity {
            let more = MoreChipView(hidden: hidden[col], typography: config.typography, calendar: calendar)
            more.onPress = { [weak self] in self?.select(col) }
            slots.append(Slot(chip: more, startCol: col, endCol: col, line: visible[col]))
        }
        slots.forEach { addSubview($0.chip) }
        hiddenTotal = hidden.reduce(0) { $0 + $1.count }

        for (col, day) in row.days.enumerated() {
            let count = row.timed[col].count + row.bars.count { ($0.startCol...$0.endCol).contains(col) }
            // 首行首日前为空白: 首日补左边线.
            dayViews[col].drawsLeadingEdge = col == 0 && row.offset > 0
            dayViews[col].onPress = { [weak self] in self?.select(col) }
            dayViews[col].configure(day, eventCount: count, hidden: hidden[col].count, config: config)
        }
        if let first = row.days.first, let last = row.days.last {
            setAccessibilityLabel("\(EventText.day(first.date)) – \(EventText.day(last.date))")
        }
        needsLayout = true
        needsDisplay = true
    }

    /// 横条只画在仍有空间 (lane < 该列可见行数) 的连续列段上; 其余列计入该列折叠.
    private func placeBars(
        _ bars: [BarSlot], visible: [Int], hidden: inout [[CalendarEvent]], typography: Typography, calendar: Calendar
    ) {
        for bar in bars {
            var runStart: Int?
            for col in bar.startCol...(bar.endCol + 1) {
                if col <= bar.endCol, bar.lane < visible[col] {
                    runStart = runStart ?? col
                    continue
                }
                if col <= bar.endCol {
                    hidden[col].append(bar.event)
                }
                if let start = runStart {
                    let chip = EventChipView(
                        event: bar.event, style: .bar(bar.continued || start > bar.startCol), dimmed: bar.isPast,
                        typography: typography, calendar: calendar
                    )
                    chip.onPress = { [weak self] in self?.select(start) }
                    slots.append(Slot(chip: chip, startCol: start, endCol: col - 1, line: bar.lane))
                    runStart = nil
                }
            }
        }
    }

    func dayCell(at col: Int) -> NSView? {
        dayViews.indices.contains(col) ? dayViews[col] : nil
    }

    private func select(_ col: Int) {
        guard dayViews.indices.contains(col) else { return }
        onSelectDay?(col, dayViews[col])
    }

    /// 日期格 / chip 不处理点击, 事件沿响应链到此; 按横坐标定位列.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let col = dayViews.firstIndex(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }) {
            select(col)
        }
    }

    /// 后台窗口首次点击即生效.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// 日期格置于 chip 之下.
    private func syncDayViews(count: Int) {
        while dayViews.count < count {
            let view = DayCellView()
            dayViews.append(view)
            addSubview(view, positioned: .below, relativeTo: nil)
        }
        while dayViews.count > count {
            dayViews.removeLast().removeFromSuperview()
        }
    }

    override func layout() {
        super.layout()
        guard let config, let row else { return }
        let width = bounds.width
        // 日下标 -> 列: 首行整体右移 offset 列 (首日落在其星期列).
        func columnX(_ index: Int) -> CGFloat {
            WeekGeometry.columnX(row.offset + index, of: row.columns, width: width)
        }
        for (index, view) in dayViews.enumerated() {
            let x = columnX(index)
            let nextX = columnX(index + 1)
            view.frame = NSRect(x: x, y: 0, width: nextX - x, height: bounds.height)
        }
        let line = config.typography.line
        let top = config.typography.header
        for slot in slots {
            let x = columnX(slot.startCol)
            slot.chip.frame = NSRect(
                x: x + 1, y: top + CGFloat(slot.line) * line, width: columnX(slot.endCol + 1) - x - 3, height: line - 1
            )
        }
    }
}

/// 事件条目: bar = 全天 / 跨天横条 (continued = 起点在本段之前); timed = 单日定时事件 (色点 + 时间 + 标题).
/// 提醒事项: 两种样式均画勾选圈 (已完成 = 实心 + 删除线 + 淡化; 逾期 = 时间红色), 无底色.
/// 只读: 点击沿响应链交给 WeekRowView (打开当日列表).
final class EventChipView: NSView {
    enum Style { case bar(_ continued: Bool), timed }

    /// AX 按下 = 打开当日列表 (鼠标点击走响应链).
    var onPress: (() -> Void)?
    private let event: CalendarEvent
    private let style: Style
    private let text: NSAttributedString
    /// 仅标题; 窄格放不下「时间 + 几个字」时改用, 保证标题可见.
    private let titleText: NSAttributedString
    /// 低于此宽度用 titleText.
    private let compactWidth: CGFloat
    private let textX: CGFloat

    init(event: CalendarEvent, style: Style, dimmed: Bool, typography: Typography, calendar: Calendar) {
        self.event = event
        self.style = style
        let fontSize = typography.fontSize
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let isOverdue = event.isOverdue
        var timeAttributes = secondary
        if isOverdue {
            timeAttributes[.foregroundColor] = NSColor.systemRed
        }
        let prefix = NSMutableAttributedString()
        switch style {
        case let .bar(continued):
            textX = event.isReminder ? Self.reminderTextX(fontSize) : 5
            if continued {
                prefix.append(NSAttributedString(string: "← ", attributes: secondary))
            } else if !event.isAllDay {
                prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: timeAttributes))
            } else if isOverdue {
                // 仅日期的逾期提醒无时间可标红: 补红色「逾期」.
                prefix.append(NSAttributedString(string: "逾期 ", attributes: timeAttributes))
            }
        case .timed:
            textX = event.isReminder ? Self.reminderTextX(fontSize) : min(9, fontSize - 1)
            prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: timeAttributes))
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let title = Self.title(event, fontSize: fontSize, paragraph: truncating)
        let text = NSMutableAttributedString(attributedString: prefix)
        text.append(title)
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        self.text = text
        titleText = title
        compactWidth = textX + prefix.size().width + fontSize * 3
        super.init(frame: .zero)
        // 提醒只按完成状态淡化: 逾期未完成的提醒在过去的日期也保持醒目.
        let dimmed = event.isReminder ? event.isCompleted : dimmed
        alphaValue = event.isIgnored ? 0.3 : dimmed ? 0.6 : 1
        let detail = EventText.detail(event, calendar: calendar)
        toolTip = detail
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(detail.replacingOccurrences(of: "\n", with: " · "))
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
        let color = event.color.color
        switch style {
        case _ where event.isReminder:
            drawCheckCircle(color)
        case .bar:
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            color.withAlphaComponent(isDark ? 0.4 : 0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        case .timed:
            let dot = min(6, bounds.height - 6)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: (bounds.height - dot) / 2, width: dot, height: dot)).fill()
        }
        let shown = bounds.width < compactWidth ? titleText : text
        let height = shown.size().height
        let rect = NSRect(x: textX, y: (bounds.height - height) / 2, width: bounds.width - textX - 1, height: height)
        shown.draw(in: rect)
    }

    /// 已完成提醒: 删除线 + 次要色.
    private static func title(
        _ event: CalendarEvent, fontSize: CGFloat, paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]
        if event.isCompleted {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        }
        return NSAttributedString(string: event.title, attributes: attributes)
    }

    private static func reminderTextX(_ fontSize: CGFloat) -> CGFloat {
        min(12, fontSize + 2)
    }

    /// 提醒勾选圈: 未完成 = 描边, 已完成 = 实心.
    private func drawCheckCircle(_ color: NSColor) {
        let size = min(textX - 4, bounds.height - 4)
        let circle = NSBezierPath(ovalIn: NSRect(x: 1.5, y: (bounds.height - size) / 2, width: size, height: size))
        if event.isCompleted {
            color.setFill()
            circle.fill()
        } else {
            color.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
        }
    }
}

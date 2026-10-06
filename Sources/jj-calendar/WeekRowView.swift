import AppKit

/// 一行: 日期格 (7 / 14 个, 月末不足一行时右侧留空) + 事件 chip; 容量不足时日期格显示 +N, 悬停列出未显示日程.
final class WeekRowView: NSView {
    struct Config: Equatable {
        let generation: Int
        let typography: Typography
        let capacity: Int
        let monthTint: Bool
    }

    private struct Slot {
        let chip: EventChipView
        let startCol: Int
        let endCol: Int
        let line: Int
    }

    private var row: WeekRow?
    private var config: Config?
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

    /// 数据 / 行高 / 容量变化时才重建 chip; 仅尺寸变化走 layout().
    func apply(_ config: Config, row: WeekRow, calendar: Calendar) {
        guard config != self.config else { return }
        self.config = config
        self.row = row
        let capacity = config.capacity

        syncDayViews(count: row.days.count)
        slots.forEach { $0.chip.removeFromSuperview() }
        slots = []
        var hidden = Array(repeating: [CalendarEvent](), count: row.days.count)
        for bar in row.bars {
            if bar.lane < capacity {
                let chip = EventChipView(
                    event: bar.event, style: .bar(bar.continued), dimmed: bar.isPast,
                    typography: config.typography, calendar: calendar
                )
                slots.append(Slot(chip: chip, startCol: bar.startCol, endCol: bar.endCol, line: bar.lane))
            } else {
                for col in bar.startCol...bar.endCol {
                    hidden[col].append(bar.event)
                }
            }
        }
        for (col, events) in row.timed.enumerated() {
            for (offset, event) in events.enumerated() {
                let line = row.lanesPerColumn[col] + offset
                if line < capacity {
                    let chip = EventChipView(
                        event: event, style: .timed, dimmed: row.days[col].isPast,
                        typography: config.typography, calendar: calendar
                    )
                    slots.append(Slot(chip: chip, startCol: col, endCol: col, line: line))
                } else {
                    hidden[col].append(event)
                }
            }
        }
        slots.forEach { addSubview($0.chip) }
        hiddenTotal = hidden.reduce(0) { $0 + $1.count }

        for (col, day) in row.days.enumerated() {
            let count = row.timed[col].count + row.bars.count { ($0.startCol...$0.endCol).contains(col) }
            dayViews[col].configure(
                day, eventCount: count, hidden: hidden[col], config: config, calendar: calendar
            )
        }
        if let first = row.days.first, let last = row.days.last {
            setAccessibilityLabel("\(EventText.day(first.date)) – \(EventText.day(last.date))")
        }
        needsLayout = true
        needsDisplay = true
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
        guard let config, let columns = row?.columns else { return }
        let width = bounds.width
        for (col, view) in dayViews.enumerated() {
            let x = WeekGeometry.columnX(col, of: columns, width: width)
            let nextX = WeekGeometry.columnX(col + 1, of: columns, width: width)
            view.frame = NSRect(x: x, y: 0, width: nextX - x, height: bounds.height)
        }
        let line = config.typography.line
        let top = config.typography.header
        for slot in slots {
            let x = WeekGeometry.columnX(slot.startCol, of: columns, width: width)
            slot.chip.frame = NSRect(
                x: x + 1, y: top + CGFloat(slot.line) * line,
                width: WeekGeometry.columnX(slot.endCol + 1, of: columns, width: width) - x - 3, height: line - 1
            )
        }
    }
}

/// 日期格: 月份底色微弱交替 (可关) + 日期号 (1 日加粗显示「N月1日」) + 星期 (周末红色) + 折叠数 +N.
/// 行首固定为每月 1 / 8 / 15… 日, 列不对应星期, 故星期画在格内.
final class DayCellView: NSView {
    private var info: DayInfo?
    private var hiddenCount = 0
    private var fontSize = Typography.standard
    private var monthTint = true
    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

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

    func configure(
        _ info: DayInfo, eventCount: Int, hidden: [CalendarEvent], config: WeekRowView.Config, calendar: Calendar
    ) {
        self.info = info
        fontSize = config.typography.fontSize
        monthTint = config.monthTint
        hiddenCount = hidden.count
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let suffix = info.isToday ? " 今天" : ""
        let folded = hidden.isEmpty ? "" : ", 另有 \(hidden.count) 个未显示"
        setAccessibilityLabel("\(info.year)年\(EventText.day(info.date))\(suffix), \(eventCount) 个日程\(folded)")
        toolTip = hidden.isEmpty ? nil : hidden.map {
            EventText.detail($0, calendar: calendar).replacingOccurrences(of: "\n", with: " · ")
        }.joined(separator: "\n")
        needsDisplay = true
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

        let isWeekend = info.weekday == 1 || info.weekday == 7
        let text = info.day == 1 ? "\(info.month)月1日" : "\(info.day)"
        let color: NSColor = info.isToday ? .white
            : info.isPast ? .secondaryLabelColor
            : isWeekend && info.day != 1 ? .secondaryLabelColor : .labelColor
        let label = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(
                ofSize: fontSize - 0.5, weight: info.day == 1 || info.isToday ? .bold : .regular
            ),
            .foregroundColor: color
        ])
        let size = label.size()
        let origin = NSPoint(x: 4, y: 1)
        if info.isToday {
            NSColor.systemRed.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: origin.x - 3, y: origin.y, width: size.width + 6, height: size.height),
                xRadius: size.height / 2, yRadius: size.height / 2
            ).fill()
        }
        label.draw(at: origin)
        let weekday = NSAttributedString(string: Self.weekdays[info.weekday - 1], attributes: [
            .font: NSFont.systemFont(ofSize: fontSize - 1.5),
            .foregroundColor: isWeekend ? NSColor.systemRed.withAlphaComponent(info.isPast ? 0.5 : 0.85)
                : NSColor.tertiaryLabelColor
        ])
        // 窄格优先保留 +N: 星期放不下则省略, +N 底色盖住溢出的日期.
        let moreX = drawMore(background: background)
        let weekdayX = origin.x + size.width + (info.isToday ? 5 : 2)
        if weekdayX + weekday.size().width <= moreX {
            weekday.draw(at: NSPoint(x: weekdayX, y: origin.y + (size.height - weekday.size().height) / 2))
        }
    }

    /// 折叠数 +N 靠右; 返回其左边界 (无折叠 = 格宽).
    private func drawMore(background: NSColor) -> CGFloat {
        guard hiddenCount > 0 else { return bounds.width }
        let more = NSAttributedString(string: "+\(hiddenCount)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 0.5, weight: .bold),
            .foregroundColor: NSColor.systemOrange
        ])
        let size = more.size()
        let x = bounds.width - size.width - 4
        background.setFill()
        NSRect(x: x - 2, y: 1, width: size.width + 2, height: size.height).fill()
        more.draw(at: NSPoint(x: x, y: 1))
        return x - 2
    }
}

/// 事件条目: bar = 全天 / 跨天横条 (continued = 上周延续段); timed = 单日定时事件 (色点 + 时间 + 标题).
final class EventChipView: NSView {
    enum Style { case bar(_ continued: Bool), timed }

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
        let prefix = NSMutableAttributedString()
        switch style {
        case let .bar(continued):
            textX = 5
            if continued {
                prefix.append(NSAttributedString(string: "← ", attributes: secondary))
            } else if !event.isAllDay {
                prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
            }
        case .timed:
            textX = min(9, fontSize - 1)
            prefix.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
        }
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: event.title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating
        ])
        let text = NSMutableAttributedString(attributedString: prefix)
        text.append(title)
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        self.text = text
        titleText = title
        compactWidth = textX + prefix.size().width + fontSize * 3
        super.init(frame: .zero)
        alphaValue = dimmed ? 0.6 : 1
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

    override func draw(_: NSRect) {
        let color = event.color.color
        switch style {
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
}

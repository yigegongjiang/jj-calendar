import AppKit

/// 一周一行: 7 个日期格 + 事件 chip; 容量不足时日期格显示 +N, 悬停列出未显示日程.
final class WeekRowView: NSView {
    struct Config: Equatable {
        let generation: Int
        let typography: Typography
        let capacity: Int
        let isColumnTop: Bool
    }

    private struct Slot {
        let chip: EventChipView
        let startCol: Int
        let endCol: Int
        let line: Int
    }

    private var row: WeekRow?
    private var config: Config?
    private let dayViews = (0..<7).map { _ in DayCellView() }
    private var slots: [Slot] = []
    /// 本周折叠 (未显示) 的日程格次数.
    private(set) var hiddenTotal = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        dayViews.forEach(addSubview)
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

        slots.forEach { $0.chip.removeFromSuperview() }
        slots = []
        var hidden = Array(repeating: [CalendarEvent](), count: 7)
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
                day, eventCount: count, hidden: hidden[col], fontSize: config.typography.fontSize, calendar: calendar
            )
        }
        if let first = row.days.first, let last = row.days.last {
            setAccessibilityLabel("\(EventText.day(first.date)) – \(EventText.day(last.date))")
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let config else { return }
        let width = bounds.width
        for (col, view) in dayViews.enumerated() {
            let x = WeekGeometry.columnX(col, width: width)
            let nextX = WeekGeometry.columnX(col + 1, width: width)
            view.frame = NSRect(x: x, y: 0, width: nextX - x, height: bounds.height)
        }
        let line = config.typography.line
        let top = config.typography.header
        for slot in slots {
            let x = WeekGeometry.columnX(slot.startCol, width: width)
            slot.chip.frame = NSRect(
                x: x + 1, y: top + CGFloat(slot.line) * line,
                width: WeekGeometry.columnX(slot.endCol + 1, width: width) - x - 3, height: line - 1
            )
        }
    }

    /// gutter: 本行含某月 1 日 (或为栏首行) 时标注月份 + 年.
    override func draw(_: NSRect) {
        let gutter = NSRect(x: 0, y: 0, width: WeekMetrics.gutter, height: bounds.height)
        NSColor.windowBackgroundColor.setFill()
        gutter.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: WeekMetrics.gutter, height: 1).fill()

        guard let row, let config else { return }
        let firstOfMonth = row.days.first { $0.inRange && $0.day == 1 }
        guard let day = firstOfMonth ?? (config.isColumnTop ? row.days.first { $0.inRange } : nil) else { return }
        let month = NSAttributedString(string: "\(day.month)月", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: firstOfMonth == nil ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        let year = NSAttributedString(string: String(day.year), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        month.draw(at: NSPoint(x: (WeekMetrics.gutter - month.size().width) / 2, y: 1))
        if bounds.height >= 26 {
            year.draw(at: NSPoint(x: (WeekMetrics.gutter - year.size().width) / 2, y: month.size().height + 1))
        }
    }
}

/// 日期格: 月份底色仅微弱交替 (主要靠阶梯粗线区分月份, 不干扰内容) + 日期号 + 折叠数 +N.
final class DayCellView: NSView {
    private var info: DayInfo?
    private var hiddenCount = 0
    private var fontSize = Typography.standard

    override var isFlipped: Bool {
        true
    }

    func configure(_ info: DayInfo, eventCount: Int, hidden: [CalendarEvent], fontSize: CGFloat, calendar: Calendar) {
        self.info = info
        self.fontSize = fontSize
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
        let background: NSColor = if !info.inRange {
            .windowBackgroundColor
        } else if info.month.isMultiple(of: 2) {
            NSColor.controlBackgroundColor.blended(withFraction: 0.025, of: .labelColor) ?? .controlBackgroundColor
        } else {
            .controlBackgroundColor
        }
        background.setFill()
        bounds.fill()

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        // 月界: 本月第一周顶边 + 1 日左边, 连成阶梯线.
        NSColor.labelColor.withAlphaComponent(0.55).setFill()
        if info.day <= 7 {
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
        if info.day == 1 {
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
        }

        let isWeekend = info.weekday == 1 || info.weekday == 7
        let text = info.day == 1 ? "\(info.month)月1日" : "\(info.day)"
        let color: NSColor = info.isToday ? .white
            : info.inRange ? (isWeekend || info.isPast ? .secondaryLabelColor : .labelColor) : .tertiaryLabelColor
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

        if hiddenCount > 0 {
            let more = NSAttributedString(string: "+\(hiddenCount)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 0.5, weight: .bold),
                .foregroundColor: NSColor.systemOrange
            ])
            more.draw(at: NSPoint(x: bounds.width - more.size().width - 4, y: 1))
        }
    }
}

/// 事件条目: bar = 全天 / 跨天横条 (continued = 上周延续段); timed = 单日定时事件 (色点 + 时间 + 标题).
final class EventChipView: NSView {
    enum Style { case bar(_ continued: Bool), timed }

    private let event: CalendarEvent
    private let style: Style
    private let text: NSAttributedString
    private let textX: CGFloat

    init(event: CalendarEvent, style: Style, dimmed: Bool, typography: Typography, calendar: Calendar) {
        self.event = event
        self.style = style
        let fontSize = typography.fontSize
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSMutableAttributedString()
        switch style {
        case let .bar(continued):
            textX = 5
            if continued {
                text.append(NSAttributedString(string: "← ", attributes: secondary))
            } else if !event.isAllDay {
                text.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
            }
        case .timed:
            textX = min(9, fontSize - 1)
            text.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
        }
        text.append(NSAttributedString(string: event.title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor
        ]))
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        self.text = text
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
        let height = text.size().height
        let rect = NSRect(x: textX, y: (bounds.height - height) / 2, width: bounds.width - textX - 1, height: height)
        text.draw(in: rect)
    }
}

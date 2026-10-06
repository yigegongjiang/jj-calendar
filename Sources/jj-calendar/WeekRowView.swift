import AppKit

/// 一周一行: 7 个日期格 + 事件 chip; 容量不足时日期格显示 +N, 悬停列出未显示日程.
final class WeekRowView: NSView {
    struct Config: Equatable {
        let generation: Int
        let lineHeight: CGFloat
        let capacity: Int
        let isColumnTop: Bool
    }

    private struct Slot {
        let chip: EventChipView
        let startCol: Int
        let endCol: Int
        let line: Int
        let isTimed: Bool
    }

    private var row: WeekRow?
    private var config: Config?
    private let dayViews = (0..<7).map { _ in DayCellView() }
    private var slots: [Slot] = []
    private var hiddenPerColumn = Array(repeating: 0, count: 7)

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
                    lineHeight: config.lineHeight, calendar: calendar
                )
                slots.append(Slot(
                    chip: chip, startCol: bar.startCol, endCol: bar.endCol, line: bar.lane, isTimed: false
                ))
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
                        lineHeight: config.lineHeight, calendar: calendar
                    )
                    slots.append(Slot(chip: chip, startCol: col, endCol: col, line: line, isTimed: true))
                } else {
                    hidden[col].append(event)
                }
            }
        }
        slots.forEach { addSubview($0.chip) }
        hiddenPerColumn = hidden.map(\.count)

        for (col, day) in row.days.enumerated() {
            let count = row.timed[col].count + row.bars.count { ($0.startCol...$0.endCol).contains(col) }
            dayViews[col].configure(day, eventCount: count, hidden: hidden[col], calendar: calendar)
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
        let line = config.lineHeight
        var timedByColumn = Array(repeating: [Slot](), count: 7)
        for slot in slots {
            if slot.isTimed {
                timedByColumn[slot.startCol].append(slot)
                continue
            }
            let x = WeekGeometry.columnX(slot.startCol, width: width)
            slot.chip.frame = NSRect(
                x: x + 1, y: WeekMetrics.header + CGFloat(slot.line) * line,
                width: WeekGeometry.columnX(slot.endCol + 1, width: width) - x - 3, height: line - 1
            )
        }
        // 列内剩余行分给被截断的定时事件换行展示; 有折叠 (+N) 的列不换行, 空间优先给条目数.
        for (col, column) in timedByColumn.enumerated() {
            guard let first = column.first, let last = column.last else { continue }
            let x = WeekGeometry.columnX(col, width: width)
            let chipWidth = WeekGeometry.columnX(col + 1, width: width) - x - 3
            var spare = hiddenPerColumn[col] > 0 ? 0 : config.capacity - last.line - 1
            var next = first.line
            for slot in column {
                let span = 1 + min(slot.chip.lineCount(width: chipWidth) - 1, max(0, spare))
                spare -= span - 1
                slot.chip.frame = NSRect(
                    x: x + 1, y: WeekMetrics.header + CGFloat(next) * line,
                    width: chipWidth, height: CGFloat(span) * line - 1
                )
                next += span
            }
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
            year.draw(at: NSPoint(x: (WeekMetrics.gutter - year.size().width) / 2, y: 14))
        }
    }
}

/// 日期格: 背景按月份交替着色 (区分月份但不断行) + 日期号 + 月界阶梯粗线 + 折叠数 +N.
final class DayCellView: NSView {
    private var info: DayInfo?
    private var hiddenCount = 0

    override var isFlipped: Bool {
        true
    }

    func configure(_ info: DayInfo, eventCount: Int, hidden: [CalendarEvent], calendar: Calendar) {
        self.info = info
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
            .underPageBackgroundColor
        } else if info.month.isMultiple(of: 2) {
            NSColor.controlBackgroundColor.blended(withFraction: 0.07, of: .labelColor) ?? .controlBackgroundColor
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
                ofSize: 10, weight: info.day == 1 || info.isToday ? .bold : .regular
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
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.systemOrange
            ])
            more.draw(at: NSPoint(x: bounds.width - more.size().width - 4, y: 1))
        }
    }
}

/// 事件条目: bar = 全天 / 跨天横条 (continued = 上周延续段); timed = 单日定时事件 (色点 + 时间 + 标题).
/// 高度超过一行时标题换行展示, 末行截断.
final class EventChipView: NSView {
    enum Style { case bar(_ continued: Bool), timed }

    private let event: CalendarEvent
    private let style: Style
    private let lineHeight: CGFloat
    private let text: NSAttributedString
    private let textX: CGFloat

    init(event: CalendarEvent, style: Style, dimmed: Bool, lineHeight: CGFloat, calendar: Calendar) {
        self.event = event
        self.style = style
        self.lineHeight = lineHeight
        let fontSize = max(8, lineHeight - 4)
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSMutableAttributedString()
        switch style {
        case let .bar(continued):
            textX = 5
            if continued {
                text.append(NSAttributedString(string: "◂ ", attributes: secondary))
            } else if !event.isAllDay {
                text.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
            }
        case .timed:
            textX = 9
            text.append(NSAttributedString(string: EventText.time(event.start) + " ", attributes: secondary))
        }
        text.append(NSAttributedString(string: event.title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor
        ]))
        self.text = text
        super.init(frame: .zero)
        alphaValue = dimmed ? 0.5 : 1
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

    /// 完整展示标题所需行数 (上限 4).
    func lineCount(width: CGFloat) -> Int {
        let available = width - textX - 1
        guard available > 0 else { return 1 }
        let height = text.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]
        ).height
        let single = text.size().height
        return min(4, max(1, Int((height / single).rounded())))
    }

    private static func paragraph(_ mode: NSLineBreakMode) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = mode
        return style
    }

    private static let truncating = paragraph(.byTruncatingTail)
    private static let wrapping = paragraph(.byCharWrapping)

    override func draw(_: NSRect) {
        let color = event.color.color
        let firstLine = lineHeight - 1
        switch style {
        case .bar:
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            color.withAlphaComponent(isDark ? 0.4 : 0.25).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
            color.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        case .timed:
            let dot = min(6, firstLine - 4)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: (firstLine - dot) / 2, width: dot, height: dot)).fill()
        }
        let multiline = bounds.height > lineHeight * 1.5
        let styled = NSMutableAttributedString(attributedString: text)
        styled.addAttribute(
            .paragraphStyle, value: multiline ? Self.wrapping : Self.truncating,
            range: NSRange(location: 0, length: styled.length)
        )
        let single = styled.size().height
        let top = (firstLine - single) / 2
        let rect = NSRect(x: textX, y: top, width: bounds.width - textX - 1, height: bounds.height - top)
        if multiline {
            styled.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            styled.draw(in: NSRect(x: rect.minX, y: top, width: rect.width, height: single))
        }
    }
}

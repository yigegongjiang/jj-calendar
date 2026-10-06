import AppKit

/// 列坐标: 左侧 gutter 显示月份, 其余宽度 7 等分.
@MainActor
enum WeekGeometry {
    static func columnX(_ col: Int, width: CGFloat) -> CGFloat {
        WeekMetrics.gutter + ((width - WeekMetrics.gutter) * CGFloat(col) / 7).rounded()
    }
}

@MainActor
enum EventText {
    private static let time = formatter("HH:mm")
    private static let day = formatter("M月d日 EEE")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = format
        return formatter
    }

    static func time(_ date: Date) -> String {
        time.timeZone = .autoupdatingCurrent
        return time.string(from: date)
    }

    static func day(_ date: Date) -> String {
        day.timeZone = .autoupdatingCurrent
        return day.string(from: date)
    }

    /// tooltip / accessibility 用完整描述.
    static func detail(_ event: CalendarEvent, calendar: Calendar) -> String {
        let lastDay = event.end > event.start ? event.end.addingTimeInterval(-1) : event.end
        let sameDay = calendar.isDate(event.start, inSameDayAs: lastDay)
        let when = switch (event.isAllDay, sameDay) {
        case (true, true): "\(day(event.start)) 全天"
        case (true, false): "\(day(event.start)) – \(day(lastDay)) 全天"
        case (false, true): "\(day(event.start)) \(time(event.start))–\(time(event.end))"
        case (false, false): "\(day(event.start)) \(time(event.start)) – \(day(event.end)) \(time(event.end))"
        }
        return [event.title, when, event.calendarTitle, event.location].compactMap(\.self).joined(separator: "\n")
    }
}

/// 一屏网格: 按 GridPlan 摆放周行 + 每栏星期表头; 不滚动.
final class WeekGridView: NSView {
    private var rows: [WeekRow] = []
    private var calendar = Calendar.current
    private var symbols: [(text: String, isWeekend: Bool)] = []
    private var generation = 0
    private var rowViews: [WeekRowView] = []
    private var headers: [WeekdayHeaderView] = []

    var typography = Typography(fontSize: Typography.standard) {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("weekGrid")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    func update(rows: [WeekRow], calendar: Calendar, symbols: [(text: String, isWeekend: Bool)]) {
        self.rows = rows
        self.calendar = calendar
        self.symbols = symbols
        generation += 1
        while rowViews.count < rows.count {
            let view = WeekRowView()
            rowViews.append(view)
            addSubview(view)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        headers.forEach { $0.symbols = symbols }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let plan = GridPlan.make(rows: rows, size: bounds.size, typography: typography)
        while headers.count < plan.columnFrames.count {
            let header = WeekdayHeaderView()
            header.symbols = symbols
            headers.append(header)
            addSubview(header)
        }
        while headers.count > plan.columnFrames.count {
            headers.removeLast().removeFromSuperview()
        }
        for (header, frame) in zip(headers, plan.columnFrames) {
            header.frame = NSRect(x: frame.minX, y: 0, width: frame.width, height: WeekMetrics.columnHeader)
        }
        for (index, placement) in plan.placements.enumerated() {
            let view = rowViews[index]
            view.frame = placement.frame
            view.apply(WeekRowView.Config(
                generation: generation, typography: typography, capacity: placement.capacity,
                isColumnTop: placement.isColumnTop
            ), row: rows[index], calendar: calendar)
        }
        let folded = rowViews.reduce(0) { $0 + $1.hiddenTotal }
        setAccessibilityLabel("\(plan.columnFrames.count) 栏, \(rows.count) 周, 字号 \(typography.fontSize), 折叠 \(folded)")
    }

    /// 栏间分隔线.
    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.tertiaryLabelColor.setFill()
        for header in headers.dropFirst() {
            NSRect(x: header.frame.minX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// 星期表头: 与周行列对齐; 每栏一个.
final class WeekdayHeaderView: NSView {
    var symbols: [(text: String, isWeekend: Bool)] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        for (col, symbol) in symbols.enumerated() {
            let label = NSAttributedString(string: symbol.text, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: symbol.isWeekend ? NSColor.secondaryLabelColor : NSColor.labelColor
            ])
            let x = WeekGeometry.columnX(col, width: bounds.width)
            let width = WeekGeometry.columnX(col + 1, width: bounds.width) - x
            let size = label.size()
            label.draw(at: NSPoint(x: x + (width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}

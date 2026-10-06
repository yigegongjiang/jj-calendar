import AppKit

/// 列坐标: 宽度按行格数 (7 / 14 / 31) 等分.
@MainActor
enum WeekGeometry {
    static func columnX(_ col: Int, of columns: Int, width: CGFloat) -> CGFloat {
        (width * CGFloat(col) / CGFloat(columns)).rounded()
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

/// 单栏网格: 按 GridPlan 自上而下摆放行; 视口放不下时纵向滚动, 放得下时无滚动条且禁回弹.
final class WeekGridView: NSView {
    private var rows: [WeekRow] = []
    private var calendar = Calendar.current
    private var generation = 0
    private var rowViews: [WeekRowView] = []
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private var scrollToTopPending = false

    var typography = Typography(fontSize: Typography.standard) {
        didSet { needsLayout = true }
    }

    /// 月份交替底色.
    var monthTint = true {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("weekGrid")
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .windowBackgroundColor
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = false
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var isFlipped: Bool {
        true
    }

    /// 起始日 / 每行格数变化 (切换区间或模式) -> 回到顶部; 数据刷新保持滚动位置.
    func update(rows: [WeekRow], calendar: Calendar) {
        if rows.first?.days.first?.date != self.rows.first?.days.first?.date
            || rows.first?.columns != self.rows.first?.columns {
            scrollToTopPending = true
        }
        self.rows = rows
        self.calendar = calendar
        generation += 1
        while rowViews.count < rows.count {
            let view = WeekRowView()
            rowViews.append(view)
            documentView.addSubview(view)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // 滚动与否只取决于视口高度 (无横向滚动条), 滚动条出现收窄宽度不会反过来改变判断.
        let viewport = scrollView.contentSize
        let plan = GridPlan.make(rows: rows, size: viewport, typography: typography)
        scrollView.hasVerticalScroller = plan.scrolls
        scrollView.verticalScrollElasticity = plan.scrolls ? .automatic : .none
        let width = scrollView.contentSize.width
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: plan.height)
        for (index, placement) in plan.placements.enumerated() {
            let view = rowViews[index]
            view.frame = NSRect(x: 0, y: placement.frame.minY, width: width, height: placement.frame.height)
            view.apply(WeekRowView.Config(
                generation: generation, typography: typography, capacity: placement.capacity,
                monthTint: monthTint
            ), row: rows[index], calendar: calendar)
        }
        if scrollToTopPending || !plan.scrolls {
            scrollToTopPending = false
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let folded = rowViews.reduce(0) { $0 + $1.hiddenTotal }
        let columns = rows.first?.columns ?? 0
        setAccessibilityLabel(
            "每行 \(columns) 格, \(rows.count) 行, \(plan.scrolls ? "滚动" : "不滚动"), 字号 \(typography.fontSize), 折叠 \(folded)"
        )
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

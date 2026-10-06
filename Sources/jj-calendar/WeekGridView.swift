import AppKit

/// 列坐标: 宽度按行格数 (7 / 14) 等分.
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
    private static let shortDay = formatter("M/d")

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

    /// 当日列表的时间列: 全天 / 起止时刻; 跨天带日期; 提醒 = 截止时刻.
    static func when(_ event: CalendarEvent, calendar: Calendar) -> String {
        shortDay.timeZone = .autoupdatingCurrent
        if event.isReminder {
            return event.isAllDay ? "全天" : time(event.start)
        }
        let lastDay = event.end > event.start ? event.end.addingTimeInterval(-1) : event.end
        return switch (event.isAllDay, calendar.isDate(event.start, inSameDayAs: lastDay)) {
        case (true, true): "全天"
        case (true, false): "全天 \(shortDay.string(from: event.start))–\(shortDay.string(from: lastDay))"
        case (false, true): "\(time(event.start))–\(time(event.end))"
        case (false, false):
            [event.start, event.end].map { "\(shortDay.string(from: $0)) \(time($0))" }.joined(separator: " – ")
        }
    }

    /// 工具栏摘要「N 个日程 · M 个提醒 · 逾期 K」; 逾期含区间前 (网格不可见), overdue = 悬停列出全部逾期提醒.
    static func summary(
        _ items: [CalendarEvent], range: MonthRange, reminders: Bool, calendar: Calendar
    ) -> (text: String, overdue: String?) {
        // 有时刻的提醒 end == start: 起点落在区间内即算.
        let inRange = items.filter { $0.start < range.end && ($0.end > range.start || $0.start >= range.start) }
        var parts = ["\(inRange.count { !$0.isReminder }) 个日程"]
        guard reminders else { return (parts[0], nil) }
        parts.append("\(inRange.count(where: \.isReminder)) 个提醒")
        let overdue = items.filter { !$0.isIgnored && $0.isOverdue && $0.start < range.end }
            .sorted { $0.start < $1.start }
        guard !overdue.isEmpty else { return (parts.joined(separator: " · "), nil) }
        parts.append("逾期 \(overdue.count)")
        let list = overdue.map { detail($0, calendar: calendar).replacingOccurrences(of: "\n", with: " · ") }
        return (parts.joined(separator: " · "), "逾期提醒:\n" + list.joined(separator: "\n"))
    }

    /// tooltip / accessibility 用完整描述.
    static func detail(_ event: CalendarEvent, calendar: Calendar) -> String {
        if event.isReminder {
            let due = event.isAllDay ? day(event.start) : "\(day(event.start)) \(time(event.start))"
            let state = event.isCompleted ? " · 已完成" : event.isOverdue ? " · 逾期" : ""
            return [event.title, "\(due) 截止", "提醒事项 · \(event.calendarTitle)\(state)", event.location]
                .compactMap(\.self).joined(separator: "\n")
        }
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

/// 单栏网格: 固定星期表头 + 按 GridPlan 自上而下摆放行; 视口放不下时纵向滚动, 放得下时无滚动条且禁回弹.
final class WeekGridView: NSView {
    private var rows: [WeekRow] = []
    private var calendar = Calendar.current
    private var rowViews: [WeekRowView] = []
    private let dayDetail = DayDetailController()
    private lazy var dayPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = dayDetail
        popover.delegate = self
        return popover
    }()

    /// transient popover 被某次 mouseDown 自动关闭时记下 (日期, 事件时间): 同一点击随后到达格子时不再重开.
    private var closedByClick: (date: Date, timestamp: TimeInterval)?

    /// 数据刷新时当日列表仍打开: layout 后重新锚定到该日期所在格 (行 / 列可能已变).
    private var pendingAnchor: (row: Int, col: Int)?
    /// 最近一次排版的各行容量; 视口外的行稍后按此补建.
    private var capacities: [Int] = []
    private var deferredApply: Task<Void, Never>?
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let header = WeekdayHeaderView()
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
        addSubview(header)
        addSubview(scrollView)
        // 滚动到尚未补建的行时立即建 chip.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(visibleRectChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
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
        while rowViews.count < rows.count {
            let view = WeekRowView()
            let index = rowViews.count
            view.onSelectDay = { [weak self] col, anchor in
                self?.toggleDay(row: index, col: col, anchor: anchor)
            }
            rowViews.append(view)
            documentView.addSubview(view)
        }
        while rowViews.count > rows.count {
            rowViews.removeLast().removeFromSuperview()
        }
        refreshDayDetail()
        needsLayout = true
    }

    /// 点击同一天 / 无日程的天 = 关闭 (后台时 transient popover 不会因外部点击关闭); 其他天 = 切换内容并移动.
    private func toggleDay(row: Int, col: Int, anchor: NSView) {
        guard rows.indices.contains(row), rows[row].days.indices.contains(col) else { return }
        let day = rows[row].days[col]
        let items = rows[row].items(at: col)
        let closed = closedByClick
        closedByClick = nil
        if dayPopover.isShown, items.isEmpty || dayDetail.date == day.date {
            dayPopover.performClose(nil)
            return
        }
        guard !items.isEmpty else { return }
        if let closed, closed.date == day.date, let event = NSApp.currentEvent, event.type == .leftMouseDown,
           event.timestamp == closed.timestamp {
            return
        }
        dayDetail.update(day: day, items: items, calendar: calendar)
        dayPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    /// 数据刷新: 打开中的日期仍在区间内 -> 原地更新内容, 否则关闭.
    private func refreshDayDetail() {
        guard dayPopover.isShown, let date = dayDetail.date else { return }
        for (index, row) in rows.enumerated() {
            if let col = row.days.firstIndex(where: { $0.date == date }) {
                dayDetail.update(day: row.days[col], items: row.items(at: col), calendar: calendar)
                pendingAnchor = (index, col)
                return
            }
        }
        dayPopover.performClose(nil)
    }

    override func layout() {
        super.layout()
        let headerHeight = WeekMetrics.columnHeader
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: bounds.height - headerHeight)
        // 滚动与否只取决于视口高度 (无横向滚动条), 滚动条出现收窄宽度不会反过来改变判断.
        let viewport = scrollView.contentSize
        let plan = GridPlan.make(rows: rows, size: viewport, typography: typography)
        scrollView.hasVerticalScroller = plan.scrolls
        scrollView.verticalScrollElasticity = plan.scrolls ? .automatic : .none
        // 表头与行同宽 (传统滚动条收窄内容区时仍列对齐).
        let width = scrollView.contentSize.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        header.columns = rows.first?.columns ?? 7
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: plan.height)
        for (index, placement) in plan.placements.enumerated() {
            rowViews[index].frame = NSRect(
                x: 0, y: placement.frame.minY, width: width, height: placement.frame.height
            )
        }
        capacities = plan.placements.map(\.capacity)
        if scrollToTopPending || !plan.scrolls {
            scrollToTopPending = false
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // 先建视口附近的行, 其余分批补建: 首屏耗时只随视口大小增长, 不随区间 / 日程总量增长.
        let near = scrollView.documentVisibleRect.insetBy(dx: 0, dy: -viewport.height)
        var later: [Int] = []
        for index in rows.indices {
            if !plan.scrolls || rowViews[index].frame.intersects(near) || index == pendingAnchor?.row {
                applyRow(index)
            } else {
                later.append(index)
            }
        }
        scheduleDeferredApply(later)
        if let anchor = pendingAnchor, dayPopover.isShown, let cell = rowViews[anchor.row].dayCell(at: anchor.col) {
            dayPopover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxX)
        }
        pendingAnchor = nil
        let folded = rowViews.reduce(0) { $0 + $1.hiddenTotal }
        let columns = rows.first?.columns ?? 0
        setAccessibilityLabel(
            "每行 \(columns) 格, \(rows.count) 行, \(plan.scrolls ? "滚动" : "不滚动"), 字号 \(typography.fontSize), 折叠 \(folded)"
        )
    }
}

extension WeekGridView {
    /// 内容 / 容量未变的行 apply 直接返回, 重复调用无代价.
    private func applyRow(_ index: Int) {
        guard capacities.indices.contains(index), index < rows.count, index < rowViews.count else { return }
        rowViews[index].apply(WeekRowView.Config(
            typography: typography, capacity: capacities[index], monthTint: monthTint
        ), row: rows[index], calendar: calendar)
    }

    /// 每批若干行, 批间让出主线程 (输入 / 绘制不被阻塞); 新一轮排版取消旧批次.
    private func scheduleDeferredApply(_ indices: [Int]) {
        deferredApply?.cancel()
        guard !indices.isEmpty else { return }
        deferredApply = Task { [weak self] in
            for start in stride(from: 0, to: indices.count, by: 6) {
                try? await Task.sleep(for: .milliseconds(1))
                guard !Task.isCancelled, let self else { return }
                indices[start..<min(start + 6, indices.count)].forEach(applyRow)
            }
        }
    }

    @objc
    private func visibleRectChanged() {
        let visible = scrollView.documentVisibleRect
        for (index, view) in rowViews.enumerated() where view.frame.intersects(visible) {
            applyRow(index)
        }
    }
}

extension WeekGridView: NSPopoverDelegate {
    func popoverWillClose(_: Notification) {
        guard let date = dayDetail.date, let event = NSApp.currentEvent, event.type == .leftMouseDown else {
            closedByClick = nil
            return
        }
        closedByClick = (date, event.timestamp)
    }
}

/// 星期表头: 周一起, 按行格数 (7 / 14) 重复; 周末红色.
final class WeekdayHeaderView: NSView {
    private static let symbols = ["一", "二", "三", "四", "五", "六", "日"]

    var columns = 7 {
        didSet { needsDisplay = columns != oldValue }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        for col in 0..<columns {
            let label = NSAttributedString(string: Self.symbols[col % 7], attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: col % 7 >= 5 ? NSColor.systemRed : NSColor.labelColor
            ])
            let x = WeekGeometry.columnX(col, of: columns, width: bounds.width)
            let width = WeekGeometry.columnX(col + 1, of: columns, width: bounds.width) - x
            let size = label.size()
            label.draw(at: NSPoint(x: x + (width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

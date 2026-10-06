import AppKit

/// 选中的月份区间: [start, end), start / end 均为月初.
struct MonthRange: Equatable {
    let start: Date
    let end: Date
    let months: Int
}

/// 年 + 月; index = 自公元 0 年起的月序号, 便于比较 / 跨年加减.
struct YearMonth: Comparable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(index: Int) {
        self.init(year: index / 12, month: index % 12 + 1)
    }

    var index: Int {
        year * 12 + month - 1
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.index < rhs.index
    }
}

struct DayInfo {
    let date: Date
    let day: Int
    let month: Int
    let year: Int
    let weekday: Int
    let isToday: Bool
    let isPast: Bool
    /// 月界阶梯线: 上方格属上月 (顶边) / 左侧格属上月且同行 (左边, 仅 1 日).
    var monthEdgeTop = false
    var monthEdgeLeading = false
}

/// 每行展示天数; 列固定周一起 (7 / 14 列), 日期连续排列 (月与月首尾衔接).
enum RowSpan: Int, CaseIterable {
    case week, twoWeeks

    var title: String {
        switch self {
        case .week: "一周"
        case .twoWeeks: "两周"
        }
    }

    /// 每行格数.
    var columns: Int {
        switch self {
        case .week: 7
        case .twoWeeks: 14
        }
    }
}

/// 某行内一段横条 (全天 / 跨天事件); 跨行 / 跨月事件每行一段.
struct BarSlot {
    let event: CalendarEvent
    let startCol: Int
    let endCol: Int
    let lane: Int
    /// 事件起点在本段之前 (上一行延续而来).
    let continued: Bool
    let isPast: Bool
}

struct WeekRow {
    /// 网格格数 (RowSpan.columns); days 可少于此 (月初 / 月末), 余下留空.
    let columns: Int
    /// days[0] 所在列 (首行 = 区间首日的星期列, 其余行 = 0); 列号 = offset + 日下标.
    let offset: Int
    let days: [DayInfo]
    let bars: [BarSlot]
    /// 每列被横条占用的 lane 数; 该列定时事件紧接其下, 不预留整行最大 lane.
    let lanesPerColumn: [Int]
    /// 每列当天的定时事件, 按开始时间排序.
    let timed: [[CalendarEvent]]
    /// 完整展示本行所需行数 = 各列 (横条 lane + 定时事件) 的最大值.
    let lines: Int
}

enum WeekMetrics {
    static let bottomPad: CGFloat = 1
    /// 星期表头高度.
    static let columnHeader: CGFloat = 16
    /// 滚动阈值: 铺满视口时每行至少展示 min(所需, 本值) 行事件; 做不到 -> 改为完整高度 + 纵向滚动.
    static let minLinesBeforeScroll = 3
}

/// 用户字号 (⌘+ / ⌘-) 决定的行高; 排版不再自动放大字号.
struct Typography: Equatable {
    static let range: ClosedRange<CGFloat> = 8...16
    static let standard: CGFloat = 10

    let fontSize: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = min(max(fontSize, Self.range.lowerBound), Self.range.upperBound)
    }

    /// 事件行高.
    var line: CGFloat {
        (fontSize + 4).rounded()
    }

    /// 日期号行高.
    var header: CGFloat {
        (fontSize + 3).rounded()
    }
}

/// 行网格: 列 = 周一起的星期; 日期连续排列, 按 RowSpan.columns 换行; 区间首日前、末日后留空.
enum WeekLayout {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        // 周一为首列, 不随系统设置.
        calendar.firstWeekday = 2
        return calendar
    }

    /// [start 月初, end 次月月初); 调用方保证 start <= end.
    static func range(start: YearMonth, end: YearMonth, calendar: Calendar) -> MonthRange {
        let months = end.index - start.index + 1
        let first = calendar.date(from: DateComponents(year: start.year, month: start.month, day: 1))!
        return MonthRange(start: first, end: calendar.date(byAdding: .month, value: months, to: first)!, months: months)
    }

    static func build(
        range: MonthRange, span: RowSpan, events: [CalendarEvent], calendar: Calendar, now: Date
    ) -> [WeekRow] {
        let today = calendar.startOfDay(for: now)
        let (days, slices) = rows(range: range, span: span, calendar: calendar, today: today)
        let rowRanges = slices.map(\.range)
        let totalDays = days.count
        // rowOf[日序号] = 所在行.
        let rowOf = rowRanges.indices.flatMap { repeatElement($0, count: rowRanges[$0].count) }

        var segments = Array(repeating: [Segment](), count: rowRanges.count)
        var timed = rowRanges.map { Array(repeating: [CalendarEvent](), count: $0.count) }

        func dayIndex(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: range.start, to: calendar.startOfDay(for: date)).day!
        }

        for event in events {
            let first = dayIndex(event.start)
            // 结束时间恰为零点 (如全天事件次日 00:00) 不占用该日.
            let endDay = calendar.startOfDay(for: event.end)
            let lastDate = event.end > event.start && endDay == event.end
                ? calendar.date(byAdding: .day, value: -1, to: endDay)! : event.end
            let last = max(first, dayIndex(lastDate))
            guard last >= 0, first < totalDays else { continue }

            if event.isAllDay || last > first {
                let lower = max(first, 0), upper = min(last, totalDays - 1)
                for row in rowOf[lower]...rowOf[upper] {
                    let bounds = rowRanges[row]
                    let start = max(lower, bounds.lowerBound)
                    segments[row].append(Segment(
                        event: event, start: start - bounds.lowerBound,
                        end: min(upper, bounds.upperBound - 1) - bounds.lowerBound, continued: start > first
                    ))
                }
            } else {
                timed[rowOf[first]][first - rowRanges[rowOf[first]].lowerBound].append(event)
            }
        }

        return rowRanges.indices.map { row in
            assemble(
                slice: slices[row], days: Array(days[rowRanges[row]]),
                segments: segments[row], timed: timed[row], today: today
            )
        }
    }

    /// 一行: 日序号区间 + 首日所在列 + 行格数.
    private struct RowSlice {
        let range: Range<Int>
        let offset: Int
        let columns: Int
    }

    /// 区间内逐日信息 + 行划分: 列 = (首日星期列 + 日序号) % columns; 列回到 0 时换行.
    private static func rows(
        range: MonthRange, span: RowSpan, calendar: Calendar, today: Date
    ) -> (days: [DayInfo], slices: [RowSlice]) {
        let totalDays = calendar.dateComponents([.day], from: range.start, to: range.end).day!
        var days: [DayInfo] = []
        days.reserveCapacity(totalDays)
        var starts: [(index: Int, column: Int)] = []
        let firstColumn = (calendar.component(.weekday, from: range.start) - calendar.firstWeekday + 7) % 7
        for index in 0..<totalDays {
            let date = calendar.date(byAdding: .day, value: index, to: range.start)!
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let column = (firstColumn + index) % span.columns
            var info = DayInfo(
                date: date, day: parts.day!, month: parts.month!, year: parts.year!, weekday: parts.weekday!,
                isToday: date == today, isPast: date < today
            )
            // 网格连续: 上方格 = index - columns.
            info.monthEdgeTop = index >= span.columns && days[index - span.columns].month != info.month
            info.monthEdgeLeading = info.day == 1 && index > 0 && column != 0
            days.append(info)
            if index == 0 || column == 0 {
                starts.append((index, column))
            }
        }
        let slices = starts.indices.map { index in
            RowSlice(
                range: starts[index].index..<(index + 1 < starts.count ? starts[index + 1].index : totalDays),
                offset: starts[index].column, columns: span.columns
            )
        }
        return (days, slices)
    }

    private struct Segment {
        let event: CalendarEvent
        let start: Int
        let end: Int
        let continued: Bool
    }

    private static func assemble(
        slice: RowSlice, days: [DayInfo], segments: [Segment], timed: [[CalendarEvent]], today: Date
    ) -> WeekRow {
        // 已忽略日历排最后: 分到靠下的 lane, 空间不足时优先被折叠.
        let sorted = segments.sorted {
            if $0.event.isIgnored != $1.event.isIgnored {
                return !$0.event.isIgnored
            }
            if $0.start != $1.start {
                return $0.start < $1.start
            }
            if $0.end != $1.end {
                return $0.end > $1.end
            }
            return ($0.event.start, $0.event.title) < ($1.event.start, $1.event.title)
        }
        // 贪心分配 lane: 取首个在 [start, end] 全空的 lane.
        var occupied: [[Bool]] = []
        var bars: [BarSlot] = []
        for segment in sorted {
            let lane = occupied.firstIndex { !$0[segment.start...segment.end].contains(true) } ?? {
                occupied.append(Array(repeating: false, count: days.count))
                return occupied.count - 1
            }()
            for col in segment.start...segment.end {
                occupied[lane][col] = true
            }
            // today 为零点: 末日早于今天 <=> 结束前一刻早于今天零点.
            bars.append(BarSlot(
                event: segment.event, startCol: segment.start, endCol: segment.end, lane: lane,
                continued: segment.continued, isPast: segment.event.end.addingTimeInterval(-1) < today
            ))
        }
        let dayEvents = timed.map {
            $0.sorted {
                $0.isIgnored != $1.isIgnored ? !$0.isIgnored : ($0.start, $0.title) < ($1.start, $1.title)
            }
        }
        let lanes = days.indices.map { col in (occupied.lastIndex { $0[col] } ?? -1) + 1 }
        return WeekRow(
            columns: slice.columns, offset: slice.offset, days: days, bars: bars, lanesPerColumn: lanes,
            timed: dayEvents, lines: days.indices.map { lanes[$0] + dayEvents[$0].count }.max() ?? 0
        )
    }
}

/// 单栏排版: 行自上而下.
/// 视口内每行能展示 min(所需, minLinesBeforeScroll) 行 -> 铺满视口不滚动, 不足部分折叠为 +N;
/// 否则 -> 每行完整高度 (无 +N), 纵向滚动.
struct GridPlan {
    struct Placement {
        let frame: NSRect
        /// 本行可展示的事件行数; 超出部分在日期格折叠为 +N.
        let capacity: Int
    }

    /// 内容总高; 不滚动时 = 视口高.
    let height: CGFloat
    let scrolls: Bool
    let placements: [Placement]

    static func make(rows: [WeekRow], size: NSSize, typography: Typography) -> GridPlan {
        let line = typography.line
        let fixed = typography.header + WeekMetrics.bottomPad
        let demand = rows.map(\.lines)
        let available = size.height - CGFloat(rows.count) * fixed
        let budget = Int(max(0, available) / line)
        let minimum = demand.reduce(0) { $0 + min($1, WeekMetrics.minLinesBeforeScroll) }
        let scrolls = available < 0 || minimum > budget
        let lines = scrolls ? demand : allocate(demand, budget: budget)
        // 不滚动时剩余高度均分给各行.
        let extra = scrolls || rows.isEmpty
            ? 0 : max(0, available - CGFloat(lines.reduce(0, +)) * line) / CGFloat(rows.count)

        var y: CGFloat = 0
        let placements = lines.map { count in
            let top = y.rounded()
            y += fixed + CGFloat(count) * line + extra
            let frame = NSRect(x: 0, y: top, width: size.width, height: y.rounded() - top)
            let capacity = Int(((frame.height - fixed) / line + 0.01).rounded(.down))
            return Placement(frame: frame, capacity: max(0, capacity))
        }
        return GridPlan(height: scrolls ? y.rounded() : size.height, scrolls: scrolls, placements: placements)
    }

    /// 行数分配 (water-filling): 求最大上限 c 使 Σmin(需求, c) ≤ budget, 余量逐行补给超限行;
    /// 事件少的行完整展示, 只折叠最拥挤的日子.
    private static func allocate(_ demand: [Int], budget: Int) -> [Int] {
        guard demand.reduce(0, +) > budget else { return demand }
        var cap = 0
        while demand.reduce(0, { $0 + min($1, cap + 1) }) <= budget {
            cap += 1
        }
        var result = demand.map { min($0, cap) }
        var left = budget - result.reduce(0, +)
        for index in demand.indices where left > 0 && demand[index] > cap {
            result[index] += 1
            left -= 1
        }
        return result
    }
}

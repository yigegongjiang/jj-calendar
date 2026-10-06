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
    let inRange: Bool
    let isToday: Bool
    let isPast: Bool
}

/// 某周内一段横条 (全天 / 跨天事件); 跨周事件每周一段.
struct BarSlot {
    let event: CalendarEvent
    let startCol: Int
    let endCol: Int
    let lane: Int
    /// 事件起点在本段之前 (上周延续而来).
    let continued: Bool
    let isPast: Bool
}

struct WeekRow {
    let days: [DayInfo]
    let bars: [BarSlot]
    /// 每列被横条占用的 lane 数; 该列定时事件紧接其下, 不预留整周最大 lane.
    let lanesPerColumn: [Int]
    /// 每列当天的定时事件, 按开始时间排序.
    let timed: [[CalendarEvent]]
    /// 完整展示本周所需行数 = 各列 (横条 lane + 定时事件) 的最大值.
    let lines: Int
}

enum WeekMetrics {
    static let gutter: CGFloat = 26
    static let bottomPad: CGFloat = 1
    /// 星期表头高度.
    static let columnHeader: CGFloat = 16
    static let minDayWidth: CGFloat = 64
    static let comfortableDayWidth: CGFloat = 140
    static let maxFlowColumns = 4
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

/// 连续周网格: 从起始月 1 日所在周到结束月末日所在周, 月份之间不断行.
enum WeekLayout {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
        return calendar
    }

    /// [start 月初, end 次月月初); 调用方保证 start <= end.
    static func range(start: YearMonth, end: YearMonth, calendar: Calendar) -> MonthRange {
        let months = end.index - start.index + 1
        let first = calendar.date(from: DateComponents(year: start.year, month: start.month, day: 1))!
        return MonthRange(start: first, end: calendar.date(byAdding: .month, value: months, to: first)!, months: months)
    }

    /// 网格 [start, end): 整周对齐.
    static func grid(for range: MonthRange, calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.dateInterval(of: .weekOfYear, for: range.start)!.start
        let lastDay = calendar.date(byAdding: .day, value: -1, to: range.end)!
        let end = calendar.dateInterval(of: .weekOfYear, for: lastDay)!.end
        return (start, end)
    }

    static func build(range: MonthRange, events: [CalendarEvent], calendar: Calendar, now: Date) -> [WeekRow] {
        let grid = grid(for: range, calendar: calendar)
        let totalDays = calendar.dateComponents([.day], from: grid.start, to: grid.end).day!
        let weekCount = totalDays / 7
        let today = calendar.startOfDay(for: now)

        var days: [DayInfo] = []
        days.reserveCapacity(totalDays)
        for offset in 0..<totalDays {
            let date = calendar.date(byAdding: .day, value: offset, to: grid.start)!
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            days.append(DayInfo(
                date: date, day: parts.day!, month: parts.month!, year: parts.year!, weekday: parts.weekday!,
                inRange: date >= range.start && date < range.end,
                isToday: date == today, isPast: date < today
            ))
        }

        var segments = Array(repeating: [Segment](), count: weekCount)
        var timed = Array(repeating: Array(repeating: [CalendarEvent](), count: 7), count: weekCount)

        func dayIndex(_ date: Date) -> Int {
            calendar.dateComponents([.day], from: grid.start, to: calendar.startOfDay(for: date)).day!
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
                for week in (lower / 7)...(upper / 7) {
                    let start = max(lower, week * 7)
                    segments[week].append(Segment(
                        event: event, start: start - week * 7, end: min(upper, week * 7 + 6) - week * 7,
                        continued: start > first
                    ))
                }
            } else {
                timed[first / 7][first % 7].append(event)
            }
        }

        return (0..<weekCount).map { week in
            assemble(
                days: Array(days[week * 7..<week * 7 + 7]), segments: segments[week], timed: timed[week],
                calendar: calendar, today: today
            )
        }
    }

    private struct Segment {
        let event: CalendarEvent
        let start: Int
        let end: Int
        let continued: Bool
    }

    private static func assemble(
        days: [DayInfo], segments: [Segment], timed: [[CalendarEvent]], calendar: Calendar, today: Date
    ) -> WeekRow {
        let sorted = segments.sorted {
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
                occupied.append(Array(repeating: false, count: 7))
                return occupied.count - 1
            }()
            for col in segment.start...segment.end {
                occupied[lane][col] = true
            }
            let lastDay = calendar.startOfDay(for: segment.event.end.addingTimeInterval(-1))
            bars.append(BarSlot(
                event: segment.event, startCol: segment.start, endCol: segment.end, lane: lane,
                continued: segment.continued, isPast: lastDay < today
            ))
        }
        let dayEvents = timed.map { $0.sorted { ($0.start, $0.title) < ($1.start, $1.title) } }
        let lanes = (0..<7).map { col in (occupied.lastIndex { $0[col] } ?? -1) + 1 }
        return WeekRow(
            days: days, bars: bars, lanesPerColumn: lanes,
            timed: dayEvents, lines: (0..<7).map { lanes[$0] + dayEvents[$0].count }.max() ?? 0
        )
    }
}

/// 一屏铺满、不滚动的排版: 周行自上而下连续, 一栏放不下时按阅读顺序续排到右侧下一栏.
/// 栏数优先保证全部展示 (不出现 +N), 其次取日宽最大者; 剩余高度均分给各周.
struct GridPlan {
    struct Placement {
        let frame: NSRect
        /// 本周可展示的事件行数; 超出部分在日期格折叠为 +N.
        let capacity: Int
        let isColumnTop: Bool
    }

    let columnFrames: [NSRect]
    let placements: [Placement]

    private struct Candidate {
        let score: CGFloat
        let chunks: [Range<Int>]
    }

    static func make(rows: [WeekRow], size: NSSize, typography: Typography) -> GridPlan {
        let line = typography.line
        let fixed = typography.header + WeekMetrics.bottomPad
        let height = size.height - WeekMetrics.columnHeader
        let fit = Int(size.width / (WeekMetrics.gutter + 7 * WeekMetrics.minDayWidth))
        let maxColumns = max(1, min(WeekMetrics.maxFlowColumns, rows.count, fit))

        var best: Candidate?
        for columns in 1...maxColumns {
            let chunks = split(rows.count, into: columns)
            // 可展示比例: 各栏 (可用行数 / 所需行数) 的最小值.
            let shown = chunks.map { chunk -> CGFloat in
                let needed = rows[chunk].reduce(0) { $0 + $1.lines }
                guard needed > 0 else { return 1 }
                let available = ((height - CGFloat(chunk.count) * fixed) / line).rounded(.down)
                return min(max(available, 0) / CGFloat(needed), 1)
            }.min() ?? 1
            let dayWidth = (size.width / CGFloat(chunks.count) - WeekMetrics.gutter) / 7
            // 折叠 (+N) 代价远高于截断: 可展示比例 4 次方, 其次日宽.
            let score = pow(shown, 4) * min(dayWidth / WeekMetrics.comfortableDayWidth, 1)
            if best == nil || score > best!.score + 0.001 {
                best = Candidate(score: score, chunks: chunks)
            }
        }
        guard let best else { return GridPlan(columnFrames: [], placements: []) }

        var columnFrames: [NSRect] = []
        var placements: [Placement] = []
        for (index, chunk) in best.chunks.enumerated() {
            let x = (size.width * CGFloat(index) / CGFloat(best.chunks.count)).rounded()
            let nextX = (size.width * CGFloat(index + 1) / CGFloat(best.chunks.count)).rounded()
            columnFrames.append(NSRect(x: x, y: 0, width: nextX - x, height: size.height))

            let available = height - CGFloat(chunk.count) * fixed
            let budget = allocate(rows[chunk].map(\.lines), budget: Int(max(0, available) / line))
            let extra = (available - CGFloat(budget.reduce(0, +)) * line) / CGFloat(chunk.count)
            var y = WeekMetrics.columnHeader
            for (offset, row) in chunk.enumerated() {
                let content = CGFloat(budget[offset]) * line + max(0, extra)
                let top = y.rounded()
                y += fixed + content
                let frame = NSRect(x: x, y: top, width: nextX - x, height: y.rounded() - top)
                let capacity = Int(((frame.height - fixed) / line + 0.01).rounded(.down))
                placements.append(Placement(
                    frame: frame, capacity: max(0, capacity), isColumnTop: row == chunk.lowerBound
                ))
            }
        }
        return GridPlan(columnFrames: columnFrames, placements: placements)
    }

    /// 行数分配 (water-filling): 求最大上限 c 使 Σmin(需求, c) ≤ budget, 余量逐行补给超限周;
    /// 事件少的周完整展示, 只折叠最拥挤的日子.
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

    private static func split(_ count: Int, into columns: Int) -> [Range<Int>] {
        let perColumn = Int((Double(count) / Double(columns)).rounded(.up))
        return stride(from: 0, to: count, by: max(1, perColumn)).map { $0..<min($0 + perColumn, count) }
    }
}

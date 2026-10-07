import EventKit

/// 新建 / 编辑草稿: 只含快速录入 / 微调字段; 备注 / 提醒 / 重复 / 地点等去系统 App 调整.
struct ItemDraft: Sendable {
    var isReminder: Bool
    var title: String
    var calendarID: String
    /// 日程 = 全天; 提醒 = 仅日期 (无时刻).
    var isAllDay: Bool
    /// 日程开始 / 提醒截止.
    var start: Date
    /// 日程结束; 全天 = 最后一天 (含). 提醒忽略.
    var end: Date
    var isCompleted: Bool
}

enum WriteError: LocalizedError {
    case missing
    case readOnly
    case guarded(String)

    var errorDescription: String? {
        switch self {
        case .missing: "条目已不存在 (可能已在别处修改 / 删除)"
        case .readOnly: "该日历 / 列表不可写"
        case let .guarded(container): "Debug 构建只允许写测试日历 / 列表: \(container)"
        }
    }
}

/// 写入: 每次按 id 重新读取目标再改, 立即 commit; 重复日程只作用于本次 (.thisEvent).
/// 变更由 EKEventStoreChanged 触发界面刷新.
extension CalendarStore {
    func save(_ draft: ItemDraft, editing item: CalendarEvent?) throws {
        guard let target = store.calendar(withIdentifier: draft.calendarID) else { throw WriteError.missing }
        let calendar = Self.writeCalendar
        if draft.isReminder {
            let reminder = try item.map(fetchReminder) ?? EKReminder(eventStore: store)
            try checkWritable(item == nil ? [target] : [reminder.calendar, target])
            let oldDue = reminder.dueDateComponents.flatMap { $0.hour == nil ? nil : calendar.date(from: $0) }
            let units: Set<Calendar.Component> = draft.isAllDay
                ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            // 无时区 (floating) = 按本地时间, 与 Reminders.app 一致.
            reminder.dueDateComponents = calendar.dateComponents(units, from: draft.start)
            let newDue = draft.isAllDay ? nil : calendar.date(from: reminder.dueDateComponents!)
            if oldDue != newDue {
                // 定在原截止时刻的提醒随截止时刻移动; 有时刻且无任何提醒时补一个, 到点通知.
                for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil && alarm.absoluteDate == oldDue {
                    reminder.removeAlarm(alarm)
                }
                if let newDue, reminder.alarms?.isEmpty ?? true {
                    reminder.addAlarm(EKAlarm(absoluteDate: newDue))
                }
            }
            reminder.title = draft.title
            reminder.calendar = target
            reminder.isCompleted = draft.isCompleted
            try store.save(reminder, commit: true)
        } else {
            let event = try item.map(fetchEvent) ?? EKEvent(eventStore: store)
            try checkWritable(item == nil ? [target] : [event.calendar, target])
            event.title = draft.title
            event.calendar = target
            event.isAllDay = draft.isAllDay
            if draft.isAllDay {
                event.startDate = calendar.startOfDay(for: draft.start)
                event.endDate = calendar.startOfDay(for: draft.end)
            } else {
                event.startDate = draft.start
                event.endDate = draft.end
            }
            try store.save(event, span: .thisEvent, commit: true)
        }
    }

    func remove(_ item: CalendarEvent) throws {
        if item.isReminder {
            let reminder = try fetchReminder(item)
            try checkWritable([reminder.calendar])
            try store.remove(reminder, commit: true)
        } else {
            let event = try fetchEvent(item)
            try checkWritable([event.calendar])
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }

    func setCompleted(_ item: CalendarEvent, _ done: Bool) throws {
        let reminder = try fetchReminder(item)
        try checkWritable([reminder.calendar])
        reminder.isCompleted = done
        try store.save(reminder, commit: true)
    }

    private static var writeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private func fetchReminder(_ item: CalendarEvent) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: item.itemID) as? EKReminder else {
            throw WriteError.missing
        }
        return reminder
    }

    /// 重复日程各次共用 id: 在显示时间附近查询, 按 id + 原定发生时间取该次.
    private func fetchEvent(_ item: CalendarEvent) throws -> EKEvent {
        let day: TimeInterval = 86400
        let predicate = store.predicateForEvents(
            withStart: item.start.addingTimeInterval(-day), end: max(item.start, item.end).addingTimeInterval(day),
            calendars: nil
        )
        guard let event = store.events(matching: predicate).first(where: {
            $0.calendarItemIdentifier == item.itemID && $0.occurrenceDate == item.occurrence
        }) else { throw WriteError.missing }
        return event
    }

    /// 原所属 + 目标容器均须可写; Debug 构建另限测试白名单 (iCloud 下精确标题), 调试不触碰真实数据.
    private func checkWritable(_ calendars: [EKCalendar?]) throws {
        for calendar in calendars {
            guard let calendar, calendar.allowsContentModifications else { throw WriteError.readOnly }
            #if DEBUG
            let source = calendar.source?.title ?? ""
            guard Self.debugWritable.contains(calendar.title), source == "iCloud" else {
                throw WriteError.guarded("\(source) / \(calendar.title)")
            }
            #endif
        }
    }

    #if DEBUG
    private static let debugWritable: Set = ["test 工作", "test 个人", "test 家庭", "test 待办", "test 购物", "test 工作跟进"]
    #endif
}

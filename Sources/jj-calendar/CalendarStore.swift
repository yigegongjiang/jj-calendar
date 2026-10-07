import AppKit
import EventKit

/// 跨 actor 传递的颜色分量; 避免依赖 NSColor 的 Sendable 标注.
struct RGBA: Sendable, Hashable {
    var red, green, blue, alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .gray
        red = rgb.redComponent
        green = rgb.greenComponent
        blue = rgb.blueComponent
        alpha = rgb.alphaComponent
    }

    var color: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// 日历或提醒事项列表 (二者 id 不重复, 共用隐藏 / 忽略状态).
struct CalendarSummary: Sendable, Equatable {
    let id: String
    let title: String
    let source: String
    let color: RGBA
    let isReminderList: Bool
    /// 可新建 / 修改其中条目 (订阅 / 节假日 / 生日日历为 false).
    let isWritable: Bool
}

/// 日程或提醒事项; 提醒事项: start = 截止时间, 无时刻 -> isAllDay + [当日 0 点, 次日 0 点), 有时刻 -> end = start.
struct CalendarEvent: Sendable, Equatable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    let color: RGBA
    let location: String?
    let isReminder: Bool
    let isCompleted: Bool
    /// calendarItemIdentifier; 重复日程各次共用, 另以 occurrence 区分.
    let itemID: String
    /// 日程的原定发生时间 (EKEvent.occurrenceDate); 提醒为 nil.
    let occurrence: Date?
    /// 所属日历 / 列表可写.
    let isWritable: Bool
    /// 重复日程 / 提醒: 编辑只作用于本次.
    let isRecurring: Bool
    /// 属于已忽略日历: 淡化 + 同位置排后 (优先被折叠); 由界面层设置.
    var isIgnored = false
    /// 逾期提醒; 由界面层按当前时间设置 (参与行比较: 到点时只重建受影响的行).
    var isOverdue = false

    /// 未完成且已过截止: 有时刻 -> 截止时刻已过; 仅日期 -> 截止日已过.
    func overdue(at now: Date) -> Bool {
        isReminder && !isCompleted && now >= overdueTime
    }

    /// 变为逾期的时刻.
    var overdueTime: Date {
        isAllDay ? end : start.addingTimeInterval(1)
    }
}

/// 授权状态; 变化时重建查询结果.
struct AccessState: Equatable, Sendable {
    let events: Bool
    let reminders: Bool

    static var current: AccessState {
        AccessState(
            events: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
            reminders: EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        )
    }

    var any: Bool {
        events || reminders
    }
}

struct CalendarSnapshot: Sendable {
    let access: AccessState
    let calendars: [CalendarSummary]
    let events: [CalendarEvent]
    /// 截止于区间内的提醒 + 区间前仍未完成的提醒 (逾期汇总用).
    let reminders: [CalendarEvent]
    /// 系统默认的新建日历 / 提醒列表.
    let defaultEventCalendarID: String?
    let defaultReminderListID: String?
}

/// 系统日历 / 提醒事项读写: 查询 + 快速录入 / 微调 (见 CalendarStore+Write).
/// actor 持有唯一的长生命周期 EKEventStore, 查询 / 写入在 actor 执行器上进行, 不阻塞主线程.
actor CalendarStore {
    let store = EKEventStore()
    private var lastAccess: AccessState?

    /// 未决定时弹系统授权框; 日历与提醒事项分别授权, 互不影响.
    func requestAccess(to type: EKEntityType) async -> Bool {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                let completion: @Sendable (Bool, (any Error)?) -> Void = { granted, _ in
                    continuation.resume(returning: granted)
                }
                if type == .event {
                    store.requestFullAccessToEvents(completion: completion)
                } else {
                    store.requestFullAccessToReminders(completion: completion)
                }
            }
        default:
            return false
        }
    }

    /// 事件 = 与 [start, end) 有交集; 调用方保证跨度 < 4 年 (EventKit 谓词上限). 未授权的一侧为空.
    func snapshot(from start: Date, to end: Date) async -> CalendarSnapshot {
        let access = AccessState.current
        // 运行中在系统设置改授权: 丢弃旧缓存 (写入均立即 commit, reset 不丢改动).
        if let lastAccess, lastAccess != access {
            store.reset()
        }
        lastAccess = access

        let calendars = access.events ? store.calendars(for: .event) : []
        let lists = access.reminders ? store.calendars(for: .reminder) : []
        let summaries = [(calendars, false), (lists, true)].flatMap { items, isReminderList in
            items.map {
                CalendarSummary(
                    id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: RGBA($0.color),
                    isReminderList: isReminderList, isWritable: $0.allowsContentModifications
                )
            }
        }
        let events: [CalendarEvent] = calendars.isEmpty ? [] : store.events(matching: store.predicateForEvents(
            withStart: start, end: end, calendars: calendars
        )).map(Self.entry)
        let defaultEventCalendarID = calendars.isEmpty ? nil : store.defaultCalendarForNewEvents?.calendarIdentifier
        guard !lists.isEmpty else {
            return CalendarSnapshot(
                access: access, calendars: summaries, events: events, reminders: [],
                defaultEventCalendarID: defaultEventCalendarID, defaultReminderListID: nil
            )
        }
        // 未完成: 截止早于 end 的全部 (含区间前逾期); 已完成: 按完成时间落在区间内取, 显示于截止日.
        // MUST NOT 用 predicateForReminders(in:): 返回历史全部提醒, 随时间无限增长.
        let incomplete = await fetch(store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: end, calendars: lists
        ))
        let completed = await fetch(store.predicateForCompletedReminders(
            withCompletionDateStarting: start, ending: end, calendars: lists
        ))
        let reminders = incomplete + completed.filter { $0.start >= start && $0.start < end }
        return CalendarSnapshot(
            access: access, calendars: summaries, events: events, reminders: reminders,
            defaultEventCalendarID: defaultEventCalendarID,
            defaultReminderListID: store.defaultCalendarForNewReminders()?.calendarIdentifier
        )
    }

    /// 回调在后台队列: EKReminder 非 Sendable, 在回调内转换.
    private func fetch(_ predicate: NSPredicate) async -> [CalendarEvent] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(Self.entry))
            }
        }
    }

    /// 他人组织的会议不可改: 改动 / 删除会同步给其他参与人.
    private nonisolated static func isOwn(_ event: EKEvent) -> Bool {
        !event.hasAttendees || event.organizer?.isCurrentUser ?? true
    }

    private nonisolated static func entry(_ event: EKEvent) -> CalendarEvent {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarID: event.calendar.calendarIdentifier,
            calendarTitle: event.calendar.title,
            color: RGBA(event.calendar.color),
            location: location?.isEmpty == false ? location : nil,
            isReminder: false,
            isCompleted: false,
            itemID: event.calendarItemIdentifier,
            occurrence: event.occurrenceDate,
            isWritable: event.calendar.allowsContentModifications && isOwn(event),
            isRecurring: event.hasRecurrenceRules || event.isDetached
        )
    }

    /// 无截止日期的提醒无法落到日期格, 不展示.
    private nonisolated static func entry(_ reminder: EKReminder) -> CalendarEvent? {
        guard let due = reminder.dueDateComponents, let list = reminder.calendar,
              let year = due.year, let month = due.month, let day = due.day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        // 仅日期 = 本地日; 有时刻: 无时区 (floating) 按本地.
        let isAllDay = due.hour == nil
        calendar.timeZone = isAllDay ? .autoupdatingCurrent : due.timeZone ?? .autoupdatingCurrent
        let parts = DateComponents(
            year: year, month: month, day: day, hour: due.hour ?? 0, minute: due.minute ?? 0, second: due.second ?? 0
        )
        guard let start = calendar.date(from: parts),
              let end = isAllDay ? calendar.date(byAdding: .day, value: 1, to: start) : start else { return nil }
        let location = reminder.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            title: reminder.title ?? "",
            start: start,
            end: end,
            isAllDay: isAllDay,
            calendarID: list.calendarIdentifier,
            calendarTitle: list.title,
            color: RGBA(list.color),
            location: location?.isEmpty == false ? location : nil,
            isReminder: true,
            isCompleted: reminder.isCompleted,
            itemID: reminder.calendarItemIdentifier,
            occurrence: nil,
            isWritable: list.allowsContentModifications,
            isRecurring: reminder.hasRecurrenceRules
        )
    }
}

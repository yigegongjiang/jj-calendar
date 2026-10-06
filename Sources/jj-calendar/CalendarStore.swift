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

struct CalendarSummary: Sendable {
    let id: String
    let title: String
    let source: String
    let color: RGBA
}

struct CalendarEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    let color: RGBA
    let location: String?
    /// 属于已忽略日历: 淡化 + 同位置排后 (优先被折叠); 由界面层设置.
    var isIgnored = false
}

struct CalendarSnapshot: Sendable {
    let calendars: [CalendarSummary]
    let events: [CalendarEvent]
}

/// 只读访问系统日历: 仅调用授权 + 查询 API; MUST NOT save / remove / commit.
/// actor 持有唯一的长生命周期 EKEventStore, 查询在 actor 执行器上进行, 不阻塞主线程.
actor CalendarStore {
    private let store = EKEventStore()

    static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    /// 返回与 [start, end) 有交集的全部事件; 调用方保证跨度 < 4 年 (EventKit 谓词上限).
    func snapshot(from start: Date, to end: Date) -> CalendarSnapshot {
        let calendars = store.calendars(for: .event)
        let summaries = calendars.map {
            CalendarSummary(
                id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: RGBA($0.color)
            )
        }
        guard !calendars.isEmpty else { return CalendarSnapshot(calendars: [], events: []) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate).map { event in
            let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier,
                calendarTitle: event.calendar.title,
                color: RGBA(event.calendar.color),
                location: location?.isEmpty == false ? location : nil
            )
        }
        return CalendarSnapshot(calendars: summaries, events: events)
    }
}

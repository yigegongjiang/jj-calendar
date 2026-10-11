#if DEBUG
import AlarmKit
import CryptoKit
import EventKit
import Foundation

/// Read-only device inspection; launch with --inspect, then copy Library/Caches/inspection.json.
@MainActor
enum Diagnostics {
    static func inspect() async {
        let service = ReminderService.shared
        do {
            try service.load()
            let lists = service.lists
            let sources = lists.map { list in
                ["list": list.title, "source": list.source.title,
                 "sourceFingerprint": fingerprint(list.source.sourceIdentifier)]
            }
            let testLists = lists.filter { ["test 待办", "test 购物", "test 工作跟进"].contains($0.title) }
            let now = Date()
            let incomplete = service.store.predicateForIncompleteReminders(
                withDueDateStarting: now.addingTimeInterval(-86400),
                ending: now.addingTimeInterval(7 * 86400), calendars: testLists
            )
            let completed = service.store.predicateForCompletedReminders(
                withCompletionDateStarting: now.addingTimeInterval(-86400), ending: now, calendars: testLists
            )
            var reminders: [[String: Any]] = []
            if !testLists.isEmpty {
                for predicate in [incomplete, completed] {
                    let ids: [String] = await withCheckedContinuation { continuation in
                        service.store.fetchReminders(matching: predicate) { rows in
                            continuation.resume(returning: (rows ?? []).map(\.calendarItemIdentifier))
                        }
                    }
                    for id in ids {
                        guard let item = service.store.calendarItem(withIdentifier: id) as? EKReminder else { continue }
                        reminders.append([
                            "id": id, "title": item.title ?? "", "list": item.calendar.title,
                            "completed": item.isCompleted, "priority": item.priority,
                            "start": dateString(item.startDateComponents), "due": dateString(item.dueDateComponents)
                        ])
                    }
                }
            }
            let alarms = try AlarmManager.shared.alarms.map {
                ["id": $0.id.uuidString, "state": String(describing: $0.state)]
            }
            let output: [String: Any] = [
                "lists": sources, "reminders": reminders, "alarms": alarms,
                "reminderAuthorization": EKEventStore.authorizationStatus(for: .reminder).rawValue,
                "allReminderLists": listMetadata(service)
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try data.write(to: directory.appendingPathComponent("inspection.json"), options: .atomic)
        } catch {
            service.report(error)
        }
    }

    private static func listMetadata(_ service: ReminderService) -> [[String: Any]] {
        service.store.calendars(for: .reminder).map {
            ["title": $0.title, "writable": $0.allowsContentModifications]
        }
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func dateString(_ components: DateComponents?) -> String {
        guard let components, let date = Calendar.current.date(from: components) else { return "" }
        return date.ISO8601Format()
    }
}
#endif

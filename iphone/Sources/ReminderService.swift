import AlarmKit
@preconcurrency import EventKit
import UIKit

extension Notification.Name {
    static let entriesChanged = Notification.Name("jj-remind.iphone.entries-changed")
}

@MainActor
final class ReminderService {
    static let shared = ReminderService()
    let store = EKEventStore()
    private(set) var state = LocalState()
    private(set) var failure: String?
    private var loaded = false
    private var loadFailure: Error?
    private var operating = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var refreshPending = false
    private var observers: [NSObjectProtocol] = []
    private var alarmTask: Task<Void, Never>?
    private var reminderAuthorization = EKEventStore.authorizationStatus(for: .reminder)

    var hasReminderAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    var hasAlarmAccess: Bool {
        AlarmManager.shared.authorizationState == .authorized
    }

    func load() throws {
        if let loadFailure {
            throw loadFailure
        }
        guard !loaded else { return }
        do {
            state = try LocalState.load()
            loaded = true
        } catch {
            loadFailure = error
            throw EntryError.message("本地状态读取失败，已停止写入：\(error.localizedDescription)")
        }
    }

    func start() {
        do { try load() } catch { report(error) }
        guard observers.isEmpty else { return }
        observers = [.EKEventStoreChanged, UIApplication.didBecomeActiveNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
        alarmTask = Task { [weak self] in
            for await _ in AlarmManager.shared.alarmUpdates {
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        Task {
            await requestMissingAccess()
            await refresh()
        }
    }

    /// First launch asks for both permissions up front instead of failing on the first entry.
    private func requestMissingAccess() async {
        do {
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                try await requestReminders()
            }
            if AlarmManager.shared.authorizationState == .notDetermined {
                try await requestAlarms()
            }
        } catch { report(error) }
    }

    func requestReminders() async throws {
        try load()
        guard try await store.requestFullAccessToReminders() else {
            throw EntryError.message("请在系统设置中允许访问提醒事项。")
        }
        store.reset()
        reminderAuthorization = EKEventStore.authorizationStatus(for: .reminder)
        await refresh()
    }

    func requestAlarms() async throws {
        guard try await AlarmManager.shared.requestAuthorization() == .authorized else {
            throw EntryError.message("请在系统设置中允许闹钟；未创建事项或闹钟。")
        }
        broadcast()
    }

    var lists: [EKCalendar] {
        guard hasReminderAccess else { return [] }
        return store.calendars(for: .reminder).filter { $0.allowsContentModifications }
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
    }

    /// Stored list if it still exists, otherwise the system default list for new reminders.
    func resolvedListID(_ stored: String?) -> String? {
        if let stored, store.calendar(withIdentifier: stored)?.allowsContentModifications == true {
            return stored
        }
        guard hasReminderAccess, let fallback = store.defaultCalendarForNewReminders(),
              fallback.allowsContentModifications else { return nil }
        return fallback.calendarIdentifier
    }

    func listTitle(_ id: String?) -> String {
        guard let id, let list = store.calendar(withIdentifier: id) else { return "选择列表" }
        return list.title
    }

    func updatePreferences(_ update: (inout Preferences) -> Void) throws {
        try load()
        var next = state
        update(&next.preferences)
        try persist(next)
    }

    func createReminder(title: String, listID: String, date: Date, priority: Int) throws {
        try load()
        try requireReminders()
        let reminder = try newReminder(title: title, listID: listID, date: date)
        reminder.priority = priority
        reminder.addAlarm(EKAlarm(absoluteDate: date))
        try store.save(reminder, commit: true)
        // Saving the item is authoritative, even if remembering the list fails.
        do { try updatePreferences { $0.reminderListID = listID } } catch { report(error) }
        broadcast()
    }

    func createAlarm(title: String, listID: String, duration: TimeInterval) async throws {
        try load()
        try requireReminders()
        guard duration >= 60, duration <= TimeInterval(Preferences.maxAlarmMinutes * 60) else {
            throw EntryError.message("请选择 1 分钟至 48 小时。")
        }
        if !hasAlarmAccess {
            try await requestAlarms()
        }
        await beginOperation()
        defer { endOperation() }
        let date = Date().addingTimeInterval(duration)
        let reminder = try newReminder(title: title, listID: listID, date: date)
        var link = AlarmLink(id: UUID(), listID: listID, fireDate: date, phase: .creating)
        reminder.url = link.marker
        var next = state
        next.alarms.append(link)
        next.preferences.alarmListID = listID
        try persist(next)
        do {
            try store.save(reminder, commit: true)
            link.reminderID = reminder.calendarItemIdentifier
            link.phase = .scheduling
            try replace(link)
            try await schedule(link, title: reminder.title)
            link.phase = .active
            try replace(link)
        } catch {
            // Persist before cleanup so a crash or denied permission can be retried.
            link.phase = .finishing
            try replace(link)
            do { try finishNow(link.id) } catch { report(error) }
            throw EntryError.message("闹钟创建失败：\(error.localizedDescription)")
        }
    }

    /// `force` drops the local link even when the reminder cannot be completed (user-confirmed removal).
    func finish(_ id: UUID, force: Bool = false) async throws {
        try load()
        await beginOperation()
        defer { endOperation() }
        try finishNow(id, force: force)
    }

    func postpone(_ id: UUID) async throws {
        try load()
        try requireReminders()
        guard hasAlarmAccess else { throw EntryError.message("闹钟权限已关闭。") }
        await beginOperation()
        defer { endOperation() }
        guard var link = state.alarms.first(where: { $0.id == id }), link.phase == .active else {
            throw EntryError.message("该闹钟已结束或正在清理。")
        }
        guard let reminder = try linkedReminder(link), !reminder.isCompleted else {
            try finishNow(id)
            return
        }
        // Ringing: snooze from now. Not yet ringing: push the pending time later, never earlier.
        link.fireDate = max(link.fireDate, Date())
            .addingTimeInterval(TimeInterval(state.preferences.snoozeMinutes * 60))
        link.phase = .scheduling
        try replace(link)
        try cancelIfPresent(id)
        do {
            setDates(reminder, date: link.fireDate)
            try checkWritable(reminder.calendar)
            try store.save(reminder, commit: true)
            try await schedule(link, title: reminder.title)
            link.phase = .active
            try replace(link)
        } catch {
            report(EntryError.message("延后未完成，打开 App 后会重试：\(error.localizedDescription)"))
            throw error
        }
    }

    /// Idempotent recovery also covers system dismissal and external completion/deletion.
    func refresh() async {
        guard !operating else { refreshPending = true; return }
        do {
            try load()
            let authorization = EKEventStore.authorizationStatus(for: .reminder)
            if authorization != reminderAuthorization {
                store.reset()
                reminderAuthorization = authorization
            }
            guard hasReminderAccess, hasAlarmAccess else { broadcast(); return }
            await beginOperation()
            defer { endOperation() }
            let alarms = try AlarmManager.shared.alarms
            for original in state.alarms {
                do {
                    try await reconcile(original, alarms: alarms)
                } catch { report(error) }
            }
        } catch { report(error) }
        broadcast()
    }

    func reminder(for link: AlarmLink) -> EKReminder? {
        guard hasReminderAccess, let id = link.reminderID else { return nil }
        return store.calendarItem(withIdentifier: id) as? EKReminder
    }

    func takeFailure() -> String? {
        defer { failure = nil }
        return failure
    }

    func report(_ error: Error) {
        failure = error.localizedDescription
        broadcast()
    }
}

extension ReminderService {
    private func reconcile(_ original: AlarmLink, alarms: [AlarmKit.Alarm]) async throws {
        var link = original
        if link.reminderID == nil {
            link.reminderID = try await recoverReminderID(link)
            try replace(link)
        }
        guard let reminder = try linkedReminder(link), !reminder.isCompleted else {
            try finishNow(link.id)
            return
        }
        switch link.phase {
        case .finishing, .creating:
            try finishNow(link.id)
        case .scheduling:
            try cancelIfPresent(link.id)
            link.fireDate = max(link.fireDate, Date().addingTimeInterval(1))
            try replace(link)
            setDates(reminder, date: link.fireDate)
            try checkWritable(reminder.calendar)
            try store.save(reminder, commit: true)
            try await schedule(link, title: reminder.title)
            link.phase = .active
            try replace(link)
        case .active:
            if !alarms.contains(where: { $0.id == link.id }) {
                try finishNow(link.id)
            }
        }
    }

    private func requireReminders() throws {
        guard hasReminderAccess else { throw EntryError.message("请先在设置中允许访问提醒事项。") }
    }

    private func beginOperation() async {
        if operating {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        operating = true
    }

    private func endOperation() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        operating = false
        broadcast()
        if refreshPending {
            refreshPending = false
            Task { await refresh() }
        }
    }

    private func newReminder(title: String, listID: String, date: Date) throws -> EKReminder {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EntryError.message("请输入事项内容。") }
        guard let list = store.calendar(withIdentifier: listID) else { throw EntryError.message("列表已不存在，请重新选择。") }
        try checkWritable(list)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = text
        reminder.isCompleted = false
        setDates(reminder, date: date)
        return reminder
    }

    private func setDates(_ reminder: EKReminder, date: Date) {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.timeZone = .current
        reminder.startDateComponents = components
        reminder.dueDateComponents = components
    }

    private func linkedReminder(_ link: AlarmLink) throws -> EKReminder? {
        try requireReminders()
        guard let reminder = reminder(for: link) else { return nil }
        // A different item behind the stored ID means ours is gone; never write to it.
        guard reminder.url == link.marker else { return nil }
        try checkWritable(reminder.calendar)
        return reminder
    }

    private func finishNow(_ id: UUID, force: Bool = false) throws {
        guard var link = state.alarms.first(where: { $0.id == id }) else { return }
        link.phase = .finishing
        try replace(link)
        do {
            try cancelIfPresent(id)
            if let reminder = try linkedReminder(link), !reminder.isCompleted {
                reminder.isCompleted = true
                try checkWritable(reminder.calendar)
                try store.save(reminder, commit: true)
            }
        } catch {
            guard force else { throw error }
        }
        var next = state
        next.alarms.removeAll { $0.id == id }
        try persist(next)
    }

    private func cancelIfPresent(_ id: UUID) throws {
        if try AlarmManager.shared.alarms.contains(where: { $0.id == id }) {
            try AlarmManager.shared.cancel(id: id)
        }
    }

    private func recoverReminderID(_ link: AlarmLink) async throws -> String? {
        guard let list = store.calendar(withIdentifier: link.listID) else { return nil }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: link.fireDate.addingTimeInterval(-86400),
            ending: link.fireDate.addingTimeInterval(86400), calendars: [list]
        )
        let marker = link.marker
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.first { $0.url == marker }?.calendarItemIdentifier)
            }
        }
    }

    private func replace(_ link: AlarmLink) throws {
        var next = state
        guard let index = next.alarms.firstIndex(where: { $0.id == link.id }) else { return }
        next.alarms[index] = link
        try persist(next)
    }

    private func persist(_ next: LocalState) throws {
        try next.save()
        state = next
        failure = nil
        broadcast()
    }

    private func broadcast() {
        NotificationCenter.default.post(name: .entriesChanged, object: nil)
    }
}

import AlarmKit
import AppIntents
import SwiftUI

struct ReminderAlarmMetadata: AlarmMetadata {
}

struct FinishReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束事项"
    static let openAppWhenRun = false
    @Parameter(title: "闹钟") var alarmID: String

    init() {
    }

    init(id: UUID) {
        alarmID = id.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { throw EntryError.message("无效的闹钟标识。") }
        do { try await ReminderService.shared.finish(id) } catch {
            ReminderService.shared.report(error)
            throw error
        }
        return .result()
    }
}

struct PostponeReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "延后事项"
    static let openAppWhenRun = false
    @Parameter(title: "闹钟") var alarmID: String

    init() {
    }

    init(id: UUID) {
        alarmID = id.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { throw EntryError.message("无效的闹钟标识。") }
        do { try await ReminderService.shared.postpone(id) } catch {
            ReminderService.shared.report(error)
            throw error
        }
        return .result()
    }
}

extension ReminderService {
    func schedule(_ link: AlarmLink, title: String) async throws {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            secondaryButton: AlarmButton(text: "延后", textColor: .white, systemImageName: "clock.arrow.circlepath"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert), metadata: ReminderAlarmMetadata(), tintColor: .orange
        )
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(max(link.fireDate, Date().addingTimeInterval(1))), attributes: attributes,
            stopIntent: FinishReminderIntent(id: link.id), secondaryIntent: PostponeReminderIntent(id: link.id)
        )
        _ = try await AlarmManager.shared.schedule(id: link.id, configuration: configuration)
    }
}

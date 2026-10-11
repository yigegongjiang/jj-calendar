import Foundation

struct Preferences: Codable {
    static let maxAlarmMinutes = 48 * 60
    var reminderListID: String?
    var alarmListID: String?
    var snoozeMinutes = 5
    var alarmDurationMinutes = 3
    var reminderDelayMinutes = 60
    var reminderPriority = 0

    init() {
    }

    private enum CodingKeys: String, CodingKey {
        case reminderListID, alarmListID, snoozeMinutes, alarmDurationMinutes, reminderDelayMinutes, reminderPriority
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reminderListID = try values.decodeIfPresent(String.self, forKey: .reminderListID)
        alarmListID = try values.decodeIfPresent(String.self, forKey: .alarmListID)
        snoozeMinutes = try values.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 5
        alarmDurationMinutes = try values.decodeIfPresent(Int.self, forKey: .alarmDurationMinutes) ?? 3
        reminderDelayMinutes = try values.decodeIfPresent(Int.self, forKey: .reminderDelayMinutes) ?? 60
        reminderPriority = try values.decodeIfPresent(Int.self, forKey: .reminderPriority) ?? 0
    }
}

/// Only unfinished operations survive locally; reminder content stays in EventKit.
struct AlarmLink: Codable, Identifiable {
    enum Phase: String, Codable {
        case creating, scheduling, active, finishing
    }

    var id: UUID
    var reminderID: String?
    var listID: String
    var fireDate: Date
    var phase: Phase

    var marker: URL {
        URL(string: "jjremind://alarm/\(id.uuidString)")!
    }
}

struct LocalState: Codable {
    var preferences = Preferences()
    var alarms: [AlarmLink] = []

    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("jj-remind/state.json")
    }

    static func load() throws -> LocalState {
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalState() }
        return try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: file))
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum EntryError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(text): text
        }
    }
}

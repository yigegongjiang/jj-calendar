import AlarmKit
import EventKit
import UIKit

/// Permissions + snooze length. Lists are picked inline on each entry screen and remembered there.
final class SettingsViewController: UITableViewController {
    private static let snoozeChoices = [1, 3, 5, 10, 15, 30, 60]
    private let service = ReminderService.shared
    private var observer: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "设置"
        observer = NotificationCenter.default.addObserver(
            forName: .entriesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tableView.reloadData() }
        }
    }

    override func numberOfSections(in _: UITableView) -> Int {
        3
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : 1
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            cell.textLabel?.text = "提醒事项"
            cell.detailTextLabel?.text = service.hasReminderAccess ? "已允许" : "未允许"
            cell.accessoryType = service.hasReminderAccess ? .none : .disclosureIndicator
        case (0, _):
            cell.textLabel?.text = "闹钟"
            cell.detailTextLabel?.text = service.hasAlarmAccess ? "已允许" : "未允许"
            cell.accessoryType = service.hasAlarmAccess ? .none : .disclosureIndicator
        case (1, _):
            cell.textLabel?.text = "延后"
            cell.detailTextLabel?.text = "\(service.state.preferences.snoozeMinutes) 分钟"
            cell.accessoryType = .disclosureIndicator
        default:
            cell.textLabel?.text = "reminds"
            cell.detailTextLabel?.text = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            cell.selectionStyle = .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0: requestAccess(reminders: indexPath.row == 0)
        case 1: chooseSnooze()
        default: break
        }
    }

    /// Asks once; after a denial only the system Settings app can grant access.
    private func requestAccess(reminders: Bool) {
        let undecided = reminders
            ? EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
            : AlarmManager.shared.authorizationState == .notDetermined
        let granted = reminders ? service.hasReminderAccess : service.hasAlarmAccess
        guard !granted else { return }
        guard undecided else {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            return
        }
        Task {
            do {
                if reminders {
                    try await service.requestReminders()
                } else {
                    try await service.requestAlarms()
                }
            } catch { showError(error) }
        }
    }

    private func chooseSnooze() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for minutes in Self.snoozeChoices {
            sheet.addAction(UIAlertAction(title: "\(minutes) 分钟", style: .default) { [weak self] _ in
                do {
                    try self?.service.updatePreferences { $0.snoozeMinutes = minutes }
                } catch { self?.showError(error) }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }
}

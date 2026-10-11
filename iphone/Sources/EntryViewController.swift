import EventKit
import UIKit

/// One screen per mode: text on top, time columns take all remaining height, action at the bottom.
final class EntryViewController: UIViewController {
    private static let priorities = [0, 9, 5, 1]
    private let mode: EntryMode
    private let service = ReminderService.shared
    private let content = UIStackView()
    private let textView = EntryTextView()
    private let priority = UISegmentedControl(items: ["无", "低", "中", "高"])
    private let picker: ColumnPicker
    private let activeStack = UIStackView()
    private let submitButton = UIButton(configuration: .filled())
    private let listItem = UIBarButtonItem()
    private var observers: [NSObjectProtocol] = []
    private var clock: Timer?
    private var submitting = false
    private var draftAnchor = Date()
    private var dayBase = Date()
    private var menuSignature = ""
    private static var launchFocused = false

    init(mode: EntryMode) {
        self.mode = mode
        picker = mode == .alarm
            ? ColumnPicker(columns: [Self.hourItems, Self.minuteItems], widths: [1, 1])
            : ColumnPicker(columns: [[], Self.clockItems(24), Self.clockItems(60)], widths: [1.6, 1, 1])
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        clock?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        listItem.accessibilityIdentifier = "entry.list"
        navigationItem.leftBarButtonItem = listItem
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
                self?.navigationController?.pushViewController(SettingsViewController(), animated: true)
            }
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = "设置"
        configureInputs()
        layout()
        observers = [
            NotificationCenter.default.addObserver(
                forName: .entriesChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareNextEntryIfEmpty() }
            }
        ]
        restoreChoices()
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        prepareNextEntryIfEmpty()
        reload()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task { await service.refresh() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let failure = service.takeFailure() {
            showError(EntryError.message(failure))
        } else if !Self.launchFocused {
            // Cold launch lands straight in the first tab's input; later appearances keep whatever the user did.
            Self.launchFocused = true
            textView.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clock?.invalidate()
        clock = nil
    }

    private var listID: String? {
        let preferences = service.state.preferences
        return service.resolvedListID(mode == .reminder ? preferences.reminderListID : preferences.alarmListID)
    }

    private static let maxHours = Preferences.maxAlarmMinutes / 60
    private static let hourItems = (0...maxHours).map { "\($0) 时" }
    private static let minuteItems = (0..<60).map { "\($0) 分" }
    private static let dayCount = 120

    private static func clockItems(_ count: Int) -> [String] {
        (0..<count).map { String(format: "%02d", $0) }
    }

    private var selectedMinutes: Int {
        mode == .alarm ? picker.selection[0] * 60 + picker.selection[1] : 0
    }

    private var reminderDate: Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: picker.selection[0], to: dayBase) ?? dayBase
        return calendar.date(bySettingHour: picker.selection[1], minute: picker.selection[2], second: 0, of: day) ?? day
    }

    private func reload() {
        updateListItem()
        if mode == .alarm {
            rebuildActiveRows()
        }
        updateSubmitState()
    }

    private func tick() {
        if mode == .alarm {
            rebuildActiveRows()
        }
        updateSubmitState()
    }

    private func submit() {
        guard !submitting, submitButton.isEnabled else { return }
        guard let listID else { showError(EntryError.message("没有可写的提醒列表。")); return }
        textView.resignFirstResponder()
        let title = textView.text ?? ""
        submitting = true
        updateSubmitState()
        Task {
            defer { submitting = false; updateSubmitState() }
            do {
                if mode == .reminder {
                    let date = reminderDate
                    try service.createReminder(
                        title: title, listID: listID, date: date,
                        priority: Self.priorities[priority.selectedSegmentIndex]
                    )
                    // Next default = same offset from whenever the next entry starts, not the same clock time.
                    let offset = (date.timeIntervalSince(Self.minuteStart(Date())) / 60).rounded()
                    try? service.updatePreferences { $0.reminderDelayMinutes = max(0, Int(offset)) }
                } else {
                    try await service.createAlarm(
                        title: title, listID: listID, duration: TimeInterval(selectedMinutes * 60)
                    )
                }
                textView.text = ""
                textView.updateSizing()
                restoreChoices()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch { showError(error) }
        }
    }

    private func manage(_ id: UUID) {
        guard let link = service.state.alarms.first(where: { $0.id == id }) else { return }
        let sheet = UIAlertController(
            title: service.reminder(for: link)?.title, message: nil, preferredStyle: .actionSheet
        )
        if link.phase == .active {
            let snooze = service.state.preferences.snoozeMinutes
            sheet.addAction(UIAlertAction(title: "延后 \(snooze) 分钟", style: .default) { [weak self] _ in
                self?.run { try await $0.postpone(id) }
            })
            sheet.addAction(UIAlertAction(title: "结束", style: .destructive) { [weak self] _ in
                self?.run { try await $0.finish(id) }
            })
        } else {
            sheet.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
                self?.run { await $0.refresh() }
            })
            sheet.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
                self?.run { try await $0.finish(id, force: true) }
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(sheet, animated: true)
    }

    private func run(_ action: @escaping @MainActor (ReminderService) async throws -> Void) {
        Task {
            do { try await action(service) } catch { showError(error) }
        }
    }

    private static func minuteStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
    }
}

extension EntryViewController {
    private func configureInputs() {
        textView.delegate = self
        picker.accessibilityIdentifier = mode == .alarm ? "entry.duration" : "entry.start"
        picker.onChange = { [weak self] in self?.pickerChanged() }
        priority.accessibilityIdentifier = "entry.priority"
        priority.addAction(UIAction { [weak self] _ in self?.rememberChoices() }, for: .valueChanged)
        activeStack.axis = .vertical
        activeStack.spacing = 6
        submitButton.accessibilityIdentifier = "entry.submit"
        submitButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
    }

    private func layout() {
        let wheel: UIView = picker
        let rows: [UIView] = mode == .alarm
            ? [textView, activeStack, wheel, submitButton]
            : [textView, wheel, priority, submitButton]
        rows.forEach(content.addArrangedSubview)
        content.axis = .vertical
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        // The wheel absorbs all free height so more rows are visible at once.
        wheel.setContentHuggingPriority(.defaultLow, for: .vertical)
        wheel.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            wheel.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            submitButton.heightAnchor.constraint(equalToConstant: 56)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc
    private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func updateListItem() {
        guard service.hasReminderAccess else {
            menuSignature = ""
            listItem.menu = nil
            listItem.primaryAction = UIAction(title: "允许提醒事项") { [weak self] _ in
                guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    return
                }
                self?.run { try await $0.requestReminders() }
            }
            return
        }
        let current = listID
        let lists = service.lists
        let signature = ([current ?? ""] + lists.map { "\($0.calendarIdentifier)=\($0.title)" }).joined(separator: "|")
        guard signature != menuSignature else { return }
        menuSignature = signature
        listItem.primaryAction = nil
        listItem.title = service.listTitle(current)
        listItem.menu = UIMenu.lists(lists, current: current) { [weak self] id in self?.select(id) }
    }

    private func select(_ id: String) {
        do {
            try service.updatePreferences {
                if mode == .reminder {
                    $0.reminderListID = id
                } else {
                    $0.alarmListID = id
                }
            }
        } catch { showError(error) }
    }

    private func rebuildActiveRows() {
        activeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let now = Date()
        for link in service.state.alarms.sorted(by: { $0.fireDate < $1.fireDate }) {
            let active = link.phase == .active
            let row = AlarmRow(
                title: service.reminder(for: link)?.title ?? "—",
                time: active ? TimeText.clock(link.fireDate) : "待处理",
                remaining: active ? TimeText.remaining(until: link.fireDate, from: now) : nil
            )
            row.addAction(UIAction { [weak self] _ in self?.manage(link.id) }, for: .touchUpInside)
            activeStack.addArrangedSubview(row)
        }
        activeStack.isHidden = activeStack.arrangedSubviews.isEmpty
    }

    private func updateSubmitState() {
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = selectedMinutes
        let validDuration = minutes > 0 && minutes <= Preferences.maxAlarmMinutes
        var configuration = submitButton.configuration ?? .filled()
        configuration.cornerStyle = .large
        configuration.title = mode == .reminder ? "保存" : "开始"
        configuration.subtitle = mode == .alarm && validDuration
            ? TimeText.clock(Date().addingTimeInterval(TimeInterval(minutes * 60))) : nil
        configuration.titleAlignment = .center
        configuration.showsActivityIndicator = submitting
        submitButton.configuration = configuration
        submitButton.isEnabled = !submitting && !text.isEmpty && (mode == .reminder || validDuration)
    }

    private func prepareNextEntryIfEmpty() {
        guard !submitting, textView.text.isEmpty else { return }
        restoreChoices()
    }

    /// Defaults follow the last choice: relative offset for reminders, duration for alarms.
    private func restoreChoices() {
        let preferences = service.state.preferences
        draftAnchor = Self.minuteStart(Date())
        if mode == .alarm {
            let duration = min(max(preferences.alarmDurationMinutes, 1), Preferences.maxAlarmMinutes)
            picker.select(duration / 60, column: 0)
            syncMinuteColumn()
            picker.select(duration % 60, column: 1)
        } else {
            let calendar = Calendar.current
            dayBase = calendar.startOfDay(for: draftAnchor)
            picker.setItems((0..<Self.dayCount).map { offset in
                TimeText.day(calendar.date(byAdding: .day, value: offset, to: dayBase) ?? dayBase, offset: offset)
            }, column: 0)
            let target = draftAnchor.addingTimeInterval(TimeInterval(max(0, preferences.reminderDelayMinutes) * 60))
            let days = calendar.dateComponents([.day], from: dayBase, to: calendar.startOfDay(for: target)).day ?? 0
            let time = calendar.dateComponents([.hour, .minute], from: target)
            picker.select(days, column: 0)
            picker.select(time.hour ?? 0, column: 1)
            picker.select(time.minute ?? 0, column: 2)
            priority.selectedSegmentIndex = Self.priorities.firstIndex(of: preferences.reminderPriority) ?? 0
        }
        picker.revealSelection()
        updateSubmitState()
    }

    private func rememberChoices() {
        do {
            try service.updatePreferences {
                if mode == .reminder {
                    let minutes = (reminderDate.timeIntervalSince(draftAnchor) / 60).rounded()
                    $0.reminderDelayMinutes = max(0, Int(minutes))
                    $0.reminderPriority = Self.priorities[priority.selectedSegmentIndex]
                } else {
                    $0.alarmDurationMinutes = selectedMinutes
                }
            }
        } catch { showError(error) }
        updateSubmitState()
    }
}

extension EntryViewController {
    private func pickerChanged() {
        if mode == .alarm {
            syncMinuteColumn()
        }
        rememberChoices()
    }

    /// 48 h is the ceiling, so its only valid minute is 0.
    private func syncMinuteColumn() {
        picker.setItems(picker.selection[0] == Self.maxHours ? ["0 分"] : Self.minuteItems, column: 1)
    }
}

extension EntryViewController: UITextViewDelegate, UIGestureRecognizerDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
        guard text == "\n" else { return true }
        textView.resignFirstResponder()
        return false
    }

    func textViewDidChange(_: UITextView) {
        textView.updateSizing()
        updateSubmitState()
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === view || touch.view === content
    }
}

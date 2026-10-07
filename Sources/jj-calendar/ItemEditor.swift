import AppKit

/// 新建 / 编辑日程或提醒 (popover 内容): 类型 (仅新建) / 标题 / 日历 / 全天 / 时间 / 完成 + 删除.
/// 快速录入 / 微调入口; 其余字段去系统 App 调整. Return = 保存, Esc = 取消.
final class ItemEditorController: NSViewController {
    struct Request {
        /// nil = 新建.
        let item: CalendarEvent?
        let isReminder: Bool
        /// 新建默认日期.
        let day: Date
        /// 候选日历 + 提醒列表 (由调用方按筛选状态过滤).
        let calendars: [CalendarSummary]
        /// 新建默认容器: 上次使用 -> 系统默认 -> 首个.
        let defaultEventCalendarID: String?
        let defaultReminderListID: String?
    }

    var onSave: ((ItemDraft, CalendarEvent?) async throws -> Void)?
    var onDelete: ((CalendarEvent) async throws -> Void)?
    var onClose: (() -> Void)?

    private static let labelWidth: CGFloat = 30
    private static let fieldWidth: CGFloat = 250

    private var request: Request?
    private var isReminder = false
    private var calendar = WeekLayout.calendar()
    private let kindControl = NSSegmentedControl(
        labels: ["日程", "提醒"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let titleField = NSTextField()
    private let calendarPopup = NSPopUpButton()
    private let calendarLabel = NSTextField(labelWithString: "日历")
    private let startLabel = NSTextField(labelWithString: "开始")
    private let startPicker = NSDatePicker()
    private let allDayCheck = NSButton(checkboxWithTitle: "全天", target: nil, action: nil)
    private let endPicker = NSDatePicker()
    private lazy var endRow = row("结束", endPicker)
    private let completedCheck = NSButton(checkboxWithTitle: "已完成", target: nil, action: nil)
    private lazy var completedRow = row("", completedCheck)
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存", target: nil, action: nil)
    /// 日程时长: 改开始时结束随之平移.
    private var duration: TimeInterval = 3600
    private var confirmingDelete = false
    private let stack = NSStackView()

    override func loadView() {
        configureControls()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [deleteButton, spacer, cancelButton, saveButton])
        buttons.spacing = 6
        let startControls = NSStackView(views: [startPicker, allDayCheck])
        startControls.spacing = 8
        stack.setViews([
            kindControl, row("标题", titleField), row(calendarLabel, calendarPopup), row(startLabel, startControls),
            endRow, completedRow, noteLabel, buttons
        ], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        buttons.widthAnchor.constraint(equalToConstant: Self.labelWidth + 6 + Self.fieldWidth).isActive = true
        // leading 对齐时 stack 不保证右侧 inset: 显式定宽.
        stack.widthAnchor.constraint(equalToConstant: Self.labelWidth + 6 + Self.fieldWidth + 20).isActive = true
        // 容器 + 四边约束: fittingSize 即内容尺寸 (popover 按它定大小).
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.setAccessibilityIdentifier("itemEditor")
        view = container
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        row(NSTextField(labelWithString: title), control)
    }

    private func row(_ label: NSTextField, _ control: NSView) -> NSStackView {
        label.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        let row = NSStackView(views: [label, control])
        row.spacing = 6
        return row
    }

    // MARK: - Load

    func load(_ request: Request) {
        _ = view
        self.request = request
        calendar = WeekLayout.calendar()
        confirmingDelete = false
        deleteButton.title = "删除"
        setBusy(false)
        let item = request.item
        isReminder = item?.isReminder ?? request.isReminder
        kindControl.isHidden = item != nil
        kindControl.selectedSegment = isReminder ? 1 : 0
        deleteButton.isHidden = item == nil
        titleField.stringValue = item?.title ?? ""
        completedCheck.state = item?.isCompleted == true ? .on : .off
        if let item {
            allDayCheck.state = item.isAllDay ? .on : .off
            startPicker.dateValue = item.start
            // 全天日程的结束按「最后一天 (含)」编辑.
            endPicker.dateValue = item.isAllDay ? lastDay(of: item) : item.end
            duration = max(0, endPicker.dateValue.timeIntervalSince(item.start))
        } else {
            applyDefaultDates(on: request.day)
        }
        showNote(nil)
        applyKind(selecting: item?.calendarID)
        fitSize()
    }

    /// 字段显隐变化后按内容定尺寸.
    private func fitSize() {
        // 取 stack 而非根视图: 根视图在 popover 窗口内带 frame 约束, fittingSize 恒为当前尺寸.
        preferredContentSize = stack.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(titleField)
    }

    /// 新建: 日程 = 定时 1 小时; 提醒 = 当日全天.
    private func applyDefaultDates(on day: Date) {
        allDayCheck.state = isReminder ? .on : .off
        applyDefaultTime(on: day)
    }

    /// 今天 = 下一个整点, 其他日 = 9:00; 日程 1 小时.
    private func applyDefaultTime(on day: Date) {
        let day = calendar.startOfDay(for: day)
        let now = Date()
        let start = calendar.isDate(day, inSameDayAs: now)
            ? calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        duration = 3600
        startPicker.dateValue = start
        endPicker.dateValue = start.addingTimeInterval(duration)
    }

    /// 按类型重填日历菜单 (按账户分组) 并切换字段.
    private func applyKind(selecting id: String?) {
        guard let request else { return }
        let calendars = request.calendars.filter { $0.isReminderList == isReminder }
        let menu = NSMenu()
        for (source, items) in Dictionary(grouping: calendars, by: \.source).sorted(by: { $0.key < $1.key }) {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(.sectionHeader(title: source.isEmpty ? "其他" : source))
            for summary in items {
                let item = NSMenuItem(title: summary.title, action: nil, keyEquivalent: "")
                item.representedObject = summary.id
                item.image = Self.swatch(summary.color.color)
                menu.addItem(item)
            }
        }
        calendarPopup.menu = menu
        let fallback = isReminder ? request.defaultReminderListID : request.defaultEventCalendarID
        let selected = [id, fallback].compactMap(\.self).first { id in calendars.contains { $0.id == id } }
            ?? calendars.first?.id
        if let item = menu.items.first(where: { $0.representedObject as? String == selected }) {
            calendarPopup.select(item)
        }
        saveButton.isEnabled = selected != nil
        calendarLabel.stringValue = isReminder ? "列表" : "日历"
        startLabel.stringValue = isReminder ? "截止" : "开始"
        endRow.isHidden = isReminder
        completedRow.isHidden = !isReminder || request.item == nil
        applyAllDay()
        if selected == nil {
            showNote(isReminder ? "筛选中无可写的提醒事项列表" : "筛选中无可写的日历", error: true)
        }
    }

    private func applyAllDay() {
        let elements: NSDatePicker.ElementFlags = allDayCheck.state == .on
            ? .yearMonthDay : [.yearMonthDay, .hourMinute]
        startPicker.datePickerElements = elements
        endPicker.datePickerElements = elements
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

// MARK: - Actions

extension ItemEditorController {
    private func configureControls() {
        kindControl.target = self
        kindControl.action = #selector(kindChanged)
        titleField.placeholderString = "标题"
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        for picker in [startPicker, endPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.calendar = calendar
            picker.locale = Locale(identifier: "zh_CN")
            picker.timeZone = .autoupdatingCurrent
            picker.target = self
        }
        startPicker.action = #selector(startChanged)
        endPicker.action = #selector(endChanged)
        allDayCheck.target = self
        allDayCheck.action = #selector(allDayChanged)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.preferredMaxLayoutWidth = Self.labelWidth + Self.fieldWidth + 6
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.hasDestructiveAction = true
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"

        let identifiers: [(NSView, String)] = [
            (kindControl, "editorKind"), (titleField, "editorTitle"), (calendarPopup, "editorCalendar"),
            (startPicker, "editorStart"), (allDayCheck, "editorAllDay"), (endPicker, "editorEnd"),
            (completedCheck, "editorCompleted"), (noteLabel, "editorNote"), (deleteButton, "editorDelete"),
            (cancelButton, "editorCancel"), (saveButton, "editorSave")
        ]
        for (control, id) in identifiers {
            control.setAccessibilityIdentifier(id)
            if let control = control as? NSControl {
                control.controlSize = .small
                control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            }
        }
        titleField.font = .systemFont(ofSize: 13)
        titleField.controlSize = .regular
        titleField.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        calendarPopup.widthAnchor.constraint(lessThanOrEqualToConstant: Self.fieldWidth).isActive = true
    }

    @objc
    private func kindChanged() {
        isReminder = kindControl.selectedSegment == 1
        applyDefaultDates(on: startPicker.dateValue)
        showNote(nil)
        applyKind(selecting: nil)
        fitSize()
    }

    @objc
    private func allDayChanged() {
        if allDayCheck.state == .off {
            // 全天 -> 定时: 首日默认时刻.
            applyDefaultTime(on: startPicker.dateValue)
        }
        applyAllDay()
    }

    @objc
    private func startChanged() {
        endPicker.dateValue = startPicker.dateValue.addingTimeInterval(duration)
    }

    @objc
    private func endChanged() {
        duration = max(0, endPicker.dateValue.timeIntervalSince(startPicker.dateValue))
    }

    @objc
    private func cancel() {
        onClose?()
    }

    @objc
    private func save() {
        guard let request, let draft = makeDraft() else { return }
        run { [onSave] in try await onSave?(draft, request.item) }
    }

    /// 两步确认: 首次点击变为「确认删除」.
    @objc
    private func deleteTapped() {
        guard let item = request?.item else { return }
        guard confirmingDelete else {
            confirmingDelete = true
            deleteButton.title = "确认删除"
            return
        }
        run { [onDelete] in try await onDelete?(item) }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        setBusy(true)
        Task {
            do {
                try await body()
                onClose?()
            } catch {
                setBusy(false)
                showNote(error.localizedDescription, error: true)
            }
        }
    }

    private func makeDraft() -> ItemDraft? {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            showNote("请输入标题", error: true)
            view.window?.makeFirstResponder(titleField)
            return nil
        }
        guard let calendarID = calendarPopup.selectedItem?.representedObject as? String else { return nil }
        let isAllDay = allDayCheck.state == .on
        // 去掉秒: 选择器只显示到分钟.
        let start = minute(startPicker.dateValue)
        let end = minute(endPicker.dateValue)
        if !isReminder, isAllDay ? calendar.startOfDay(for: end) < calendar.startOfDay(for: start) : end < start {
            showNote("结束早于开始", error: true)
            return nil
        }
        return ItemDraft(
            isReminder: isReminder, title: title, calendarID: calendarID, isAllDay: isAllDay, start: start,
            end: end, isCompleted: isReminder && completedCheck.state == .on
        )
    }

    private func minute(_ date: Date) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    private func lastDay(of item: CalendarEvent) -> Date {
        calendar.startOfDay(for: item.end > item.start ? item.end.addingTimeInterval(-1) : item.end)
    }

    private func setBusy(_ busy: Bool) {
        for button in [saveButton, cancelButton, deleteButton] {
            button.isEnabled = !busy
        }
        if !busy {
            saveButton.isEnabled = calendarPopup.selectedItem != nil
        }
    }

    /// 重复日程提示 / 错误 (红色); 无内容时隐藏.
    private func showNote(_ text: String?, error: Bool = false) {
        let recurring = request?.item.flatMap { item in
            item.isRecurring ? item.isReminder ? "重复提醒: 修改 / 删除作用于整个系列" : "重复日程: 修改 / 删除只作用于本次" : nil
        }
        let text = text ?? recurring
        noteLabel.stringValue = text ?? ""
        noteLabel.textColor = error ? .systemRed : .secondaryLabelColor
        noteLabel.isHidden = text == nil
        if request != nil {
            fitSize()
        }
    }
}

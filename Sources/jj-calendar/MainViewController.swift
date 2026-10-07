import AppKit
import EventKit

/// 主界面: 起始年月 + 时长 -> 单栏网格展示区间内全部日程 + 提醒事项; 每行一周 / 两周, 拥挤时纵向滚动.
final class MainViewController: NSViewController {
    let store = CalendarStore()

    private let startYearPopup = SettablePopUpButton()
    private let startMonthPopup = SettablePopUpButton()
    private let durationPopup = SettablePopUpButton()
    let calendarsButton = NSButton(title: "日历", target: nil, action: nil)
    /// 任一页签只显示中才出现: 一键还原.
    let soloRestoreButton = NSButton(title: "", target: nil, action: nil)
    let filterController = CalendarFilterController()
    lazy var filterPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = filterController
        return popover
    }()

    private let rowSpanControl = NSSegmentedControl(
        labels: RowSpan.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let monthTintToggle = NSButton(checkboxWithTitle: "忽略背景色", target: nil, action: nil)
    /// 标题栏右侧按钮区: 开关类按钮统一追加到此 stack; AppDelegate 挂到窗口.
    private(set) lazy var titlebarAccessory: NSTitlebarAccessoryViewController = {
        let stack = NSStackView(views: [rowSpanControl, monthTintToggle])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.frame.size = stack.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        return accessory
    }()

    private let summaryLabel = NSTextField(labelWithString: "")
    /// 日历 / 提醒事项只授权其一时显示, 直达对应隐私设置.
    let accessButton = NSButton(title: "", target: nil, action: nil)
    let gridView = WeekGridView()
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "打开日历隐私设置", target: nil, action: nil)

    private var calendar = WeekLayout.calendar()
    private var start = YearMonth(year: 2000, month: 1)
    private var months = 3
    /// 上次同步时的本月; 跨月时起始月仍为旧本月 -> 跟随到新本月.
    private var currentMonth = YearMonth(year: 2000, month: 1)
    var selection = FilterSelection.saved
    private(set) var snapshot: CalendarSnapshot?
    private var generation = 0
    private var reloadTask: Task<Void, Never>?
    /// 下一个提醒到点变逾期时重排 (跨天另由 NSCalendarDayChanged 处理).
    private var overdueTask: Task<Void, Never>?
    private let observers = ObserverTokens()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        restoreRange()
        configureControls()

        let toolbar = NSStackView(views: [
            startYearPopup, startMonthPopup, durationPopup,
            calendarsButton, soloRestoreButton, accessButton, summaryLabel
        ])
        toolbar.spacing = 4
        toolbar.setCustomSpacing(12, after: durationPopup)
        toolbar.setCustomSpacing(12, after: calendarsButton)
        toolbar.setCustomSpacing(12, after: soloRestoreButton)
        toolbar.setCustomSpacing(12, after: accessButton)
        toolbar.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        toolbar.setHuggingPriority(.defaultHigh, for: .vertical)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("summaryLabel")

        messageLabel.alignment = .center
        settingsButton.target = self
        settingsButton.action = #selector(openPrivacySettings)
        let message = NSStackView(views: [messageLabel, settingsButton])
        message.orientation = .vertical
        message.isHidden = true

        for subview in [toolbar, gridView, message] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            gridView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
        self.view = view
        observeChanges()
        requestAccess()
    }

    // MARK: - Controls

    private func configureControls() {
        startMonthPopup.addItems(withTitles: (1...12).map { "\($0)月" })
        for (months, title) in Self.durations {
            durationPopup.addItem(withTitle: title)
            durationPopup.lastItem?.tag = months
        }
        syncRangeControls()

        for (popup, id) in [
            (startYearPopup, "startYearPopup"), (startMonthPopup, "startMonthPopup"), (durationPopup, "durationPopup")
        ] {
            popup.target = self
            popup.action = #selector(rangeChanged(_:))
            popup.setAccessibilityIdentifier(id)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        configureFilterControls()
        rowSpanControl.setAccessibilityIdentifier("rowSpanControl")
        rowSpanControl.target = self
        rowSpanControl.action = #selector(rowSpanChanged)
        rowSpanControl.selectedSegment = (RowSpan(rawValue: ConfigStore.config.rowSpan) ?? .week).rawValue
        monthTintToggle.setAccessibilityIdentifier("monthTintToggle")
        monthTintToggle.target = self
        monthTintToggle.action = #selector(monthTintToggled)
        for control in [rowSpanControl, monthTintToggle] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        let ignoreTint = ConfigStore.config.ignoreMonthTint
        monthTintToggle.state = ignoreTint ? .on : .off
        gridView.monthTint = !ignoreTint
        applyFontSize(ConfigStore.config.fontSize)
        accessButton.setAccessibilityIdentifier("accessButton")
        accessButton.target = self
        accessButton.action = #selector(openPrivacySettings)
        accessButton.isHidden = true
        for button in [calendarsButton, soloRestoreButton, accessButton] {
            button.controlSize = .small
            button.bezelStyle = .push
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
    }

    @objc
    private func monthTintToggled() {
        let ignoreTint = monthTintToggle.state == .on
        ConfigStore.updateConfig { $0.ignoreMonthTint = ignoreTint }
        gridView.monthTint = !ignoreTint
    }

    @objc
    private func rowSpanChanged() {
        ConfigStore.updateConfig { $0.rowSpan = rowSpan.rawValue }
        relayout()
    }

    /// 值 = RowSpan.rawValue; 越界 (-1) 回退一周.
    private var rowSpan: RowSpan {
        RowSpan(rawValue: rowSpanControl.selectedSegment) ?? .week
    }

    private var range: MonthRange {
        WeekLayout.range(start: start, end: YearMonth(index: start.index + months - 1), calendar: calendar)
    }

    // MARK: - Data

    func reload() {
        guard AccessState.current.any else { return }
        calendar = WeekLayout.calendar()
        generation += 1
        let token = generation
        Task {
            let result = await store.snapshot(from: range.start, to: range.end)
            guard token == generation else { return }
            snapshot = result
            rebuildCalendarsMenu(result.calendars)
            relayout()
        }
    }

    /// 系统日历变化 / 时区 / 语言变更 -> 防抖后重新读取.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        let reloadNames: [Notification.Name] = [
            .EKEventStoreChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification
        ]
        for name in reloadNames {
            observers.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            })
        }
        // 跨天 -> 刷新「今天」/ 已过日期; 年份候选也随之更新.
        let dayChanged = Notification.Name.NSCalendarDayChanged
        observers.tokens.append(center.addObserver(forName: dayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followCurrentMonth()
            }
        })
        // 设置中授权后回到窗口即生效.
        let activated = NSApplication.didBecomeActiveNotification
        observers.tokens
            .append(center.addObserver(forName: activated, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AccessState.current != self.snapshot?.access else { return }
                    self.applyAccess()
                }
            })
    }

    func relayout() {
        guard let snapshot else { return }
        let range = range
        let now = Date()
        let disabled = FilterSource.disabled
        let items = (snapshot.events + snapshot.reminders).compactMap { event -> CalendarEvent? in
            guard !selection.hidden.contains(event.calendarID),
                  !disabled.contains(FilterSource(isReminder: event.isReminder)) else { return nil }
            var event = event
            event.isIgnored = selection.ignored.contains(event.calendarID)
            event.isOverdue = event.overdue(at: now)
            return event
        }
        let rows = WeekLayout.build(range: range, span: rowSpan, events: items, calendar: calendar, now: now)
        gridView.update(rows: rows, calendar: calendar)
        let sources = Set(FilterSource.allCases).subtracting(disabled)
            .filter { $0 == .calendars || snapshot.access.reminders }
        let summary = EventText.summary(items, range: range, sources: sources, calendar: calendar)
        summaryLabel.stringValue = summary.text
        summaryLabel.toolTip = summary.overdue
        scheduleOverdueRefresh(items)
    }

    private func scheduleOverdueRefresh(_ items: [CalendarEvent]) {
        overdueTask?.cancel()
        let next = items.lazy.filter { $0.isReminder && !$0.isCompleted && !$0.isOverdue }.map(\.overdueTime).min()
        guard let next else { return }
        overdueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.relayout()
        }
    }
}

// MARK: - Range (起始年月 + 时长, 可跨年)

extension MainViewController {
    private static let durations = [
        (1, "1 个月"), (3, "3 个月"), (6, "半年"), (9, "9 个月"),
        (12, "1 年"), (15, "1 年 3 个月"), (18, "1 年半"), (21, "1 年 9 个月"), (24, "2 年")
    ]

    private static func thisMonth(_ calendar: Calendar) -> YearMonth {
        let now = calendar.dateComponents([.year, .month], from: Date())
        return YearMonth(year: now.year!, month: now.month!)
    }

    /// 年份候选 = 当前年 ±3 (运行时计算) ∪ 起始年; 选中项与 start / months 同步.
    private func syncRangeControls() {
        let current = calendar.component(.year, from: Date())
        let years = min(current - 3, start.year)...max(current + 3, start.year)
        startYearPopup.removeAllItems()
        startYearPopup.addItems(withTitles: years.map { "\($0)年" })
        for (item, year) in zip(startYearPopup.itemArray, years) {
            item.tag = year
        }
        startYearPopup.selectItem(withTag: start.year)
        startMonthPopup.selectItem(at: start.month - 1)
        durationPopup.selectItem(withTag: months)
    }

    private func restoreRange() {
        currentMonth = Self.thisMonth(calendar)
        start = currentMonth
        let saved = ConfigStore.config.months
        months = Self.durations.contains { $0.0 == saved } ? saved : 3
    }

    /// 跨天: 跨月且起始月仍是旧本月 -> 起始月跟随; 年份候选 / 「今天」随之刷新.
    private func followCurrentMonth() {
        let now = Self.thisMonth(calendar)
        if now != currentMonth, start == currentMonth {
            start = now
            reload()
        }
        currentMonth = now
        syncRangeControls()
        relayout()
    }

    @objc
    private func rangeChanged(_: NSPopUpButton) {
        start = YearMonth(year: startYearPopup.selectedTag(), month: startMonthPopup.indexOfSelectedItem + 1)
        months = durationPopup.selectedTag()
        ConfigStore.updateConfig { [months] in $0.months = months }
        syncRangeControls()
        reload()
    }
}

// MARK: - Font size (仅菜单 ⌘+ / ⌘- / ⌘0, 经响应链调用; 界面不放字号控件)

extension MainViewController {
    @objc
    func increaseFontSize(_: Any?) {
        applyFontSize(gridView.typography.fontSize + 1)
    }

    @objc
    func decreaseFontSize(_: Any?) {
        applyFontSize(gridView.typography.fontSize - 1)
    }

    @objc
    func resetFontSize(_: Any?) {
        applyFontSize(Typography.standard)
    }

    private func applyFontSize(_ size: CGFloat) {
        let typography = Typography(fontSize: size)
        gridView.typography = typography
        ConfigStore.updateConfig { $0.fontSize = Double(typography.fontSize) }
    }
}

/// block observer token 持有者: 随 controller 释放时注销 (MainActor deinit 不能访问隔离状态).
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

import AppKit
import EventKit

/// 主界面: 起始年月 + 时长 -> 一屏连续周网格展示区间内全部日程 (不滚动).
final class MainViewController: NSViewController {
    private enum Key {
        /// 时长 (月数); 起始月不持久化, 每次启动为本月.
        static let months = "range.months"
        static let hiddenCalendars = "hiddenCalendarIDs"
        static let fontSize = "fontSize"
        static let ignoreMonthTint = "ignoreMonthTint"
    }

    private let store = CalendarStore()
    private let defaults = UserDefaults.standard

    private let startYearPopup = SettablePopUpButton()
    private let startMonthPopup = SettablePopUpButton()
    private let durationPopup = SettablePopUpButton()
    private let calendarsButton = NSButton(title: "日历", target: nil, action: nil)
    private let filterController = CalendarFilterController()
    private lazy var filterPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = filterController
        return popover
    }()

    private let monthTintToggle = NSButton(checkboxWithTitle: "忽略背景色", target: nil, action: nil)
    /// 标题栏右侧按钮区: 开关类按钮统一追加到此 stack; AppDelegate 挂到窗口.
    private(set) lazy var titlebarAccessory: NSTitlebarAccessoryViewController = {
        let stack = NSStackView(views: [monthTintToggle])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.frame.size = stack.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        return accessory
    }()

    private let summaryLabel = NSTextField(labelWithString: "")
    private let gridView = WeekGridView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "打开日历隐私设置", target: nil, action: nil)

    private var calendar = WeekLayout.calendar()
    private var start = YearMonth(year: 2000, month: 1)
    private var months = 3
    /// 上次同步时的本月; 跨月时起始月仍为旧本月 -> 跟随到新本月.
    private var currentMonth = YearMonth(year: 2000, month: 1)
    private var hiddenCalendarIDs: Set<String>
    private var snapshot: CalendarSnapshot?
    private var generation = 0
    private var reloadTask: Task<Void, Never>?
    private let observers = ObserverTokens()

    init() {
        hiddenCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: Key.hiddenCalendars) ?? [])
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
            calendarsButton, summaryLabel
        ])
        toolbar.spacing = 4
        toolbar.setCustomSpacing(12, after: durationPopup)
        toolbar.setCustomSpacing(12, after: calendarsButton)
        toolbar.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        toolbar.setHuggingPriority(.defaultHigh, for: .vertical)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        calendarsButton.setAccessibilityIdentifier("calendarsButton")
        calendarsButton.target = self
        calendarsButton.action = #selector(showCalendarFilter)
        calendarsButton.controlSize = .small
        calendarsButton.bezelStyle = .push
        calendarsButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        filterController.onChange = { [weak self] hidden in
            self?.hiddenCalendarIDs = hidden
            self?.persistHidden()
        }
        monthTintToggle.setAccessibilityIdentifier("monthTintToggle")
        monthTintToggle.target = self
        monthTintToggle.action = #selector(monthTintToggled)
        monthTintToggle.controlSize = .small
        monthTintToggle.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let ignoreTint = defaults.bool(forKey: Key.ignoreMonthTint)
        monthTintToggle.state = ignoreTint ? .on : .off
        gridView.monthTint = !ignoreTint
        let savedFont = defaults.object(forKey: Key.fontSize) as? Double
        applyFontSize(savedFont.map { CGFloat($0) } ?? Typography.standard)
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("summaryLabel")
    }

    @objc
    private func monthTintToggled() {
        let ignoreTint = monthTintToggle.state == .on
        defaults.set(ignoreTint, forKey: Key.ignoreMonthTint)
        gridView.monthTint = !ignoreTint
    }

    private var range: MonthRange {
        WeekLayout.range(start: start, end: YearMonth(index: start.index + months - 1), calendar: calendar)
    }

    // MARK: - Data

    private func requestAccess() {
        Task {
            if await store.requestAccess() {
                showMessage(nil)
                reload()
            } else {
                showMessage("无日历完全访问权限: 系统设置 > 隐私与安全性 > 日历 中允许 jj-calendar 后返回本窗口.")
            }
        }
    }

    private func showMessage(_ text: String?) {
        messageLabel.stringValue = text ?? ""
        messageLabel.superview?.isHidden = text == nil
        gridView.isHidden = text != nil
    }

    @objc
    private func openPrivacySettings() {
        let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        NSWorkspace.shared.open(URL(string: url)!)
    }

    private func reload() {
        guard CalendarStore.hasFullAccess else { return }
        calendar = WeekLayout.calendar()
        generation += 1
        let token = generation
        let grid = WeekLayout.grid(for: range, calendar: calendar)
        Task {
            let result = await store.snapshot(from: grid.start, to: grid.end)
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
                    guard let self, self.snapshot == nil, CalendarStore.hasFullAccess else { return }
                    self.showMessage(nil)
                    self.reload()
                }
            })
    }

    private func relayout() {
        guard let snapshot else { return }
        let range = range
        let events = snapshot.events.filter { !hiddenCalendarIDs.contains($0.calendarID) }
        let rows = WeekLayout.build(range: range, events: events, calendar: calendar, now: Date())
        gridView.update(rows: rows, calendar: calendar, symbols: weekdaySymbols())

        let inRange = events.count { $0.end > range.start && $0.start < range.end }
        summaryLabel.stringValue = "\(inRange) 个日程"
    }

    private func weekdaySymbols() -> [(text: String, isWeekend: Bool)] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let symbols = formatter.shortStandaloneWeekdaySymbols!
        return (0..<7).map { col in
            let weekday = (calendar.firstWeekday - 1 + col) % 7 + 1
            return (symbols[weekday - 1], weekday == 1 || weekday == 7)
        }
    }
}

// MARK: - Range (起始年月 + 时长, 可跨年)

extension MainViewController {
    private static let durations = [
        (1, "1 个月"), (3, "3 个月"), (6, "半年"), (9, "9 个月"),
        (12, "1 年"), (15, "1 年 3 个月"), (18, "1 年半"), (21, "1 年 9 个月")
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
        let saved = defaults.integer(forKey: Key.months)
        months = Self.durations.contains { $0.0 == saved } ? saved : 3
        // v0.2.x: 起止年月持久化.
        for legacy in ["range.start", "range.end", "range.year", "range.startMonth", "range.endMonth"] {
            defaults.removeObject(forKey: legacy)
        }
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
        defaults.set(months, forKey: Key.months)
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
        defaults.set(Double(typography.fontSize), forKey: Key.fontSize)
    }
}

// MARK: - Calendars filter

extension MainViewController {
    private func rebuildCalendarsMenu(_ calendars: [CalendarSummary]) {
        filterController.update(calendars: calendars, hidden: hiddenCalendarIDs)
        let hidden = calendars.count { hiddenCalendarIDs.contains($0.id) }
        calendarsButton.title = hidden == 0 ? "日历 ▾" : "日历 (隐藏 \(hidden)) ▾"
    }

    /// 再次点击关闭: App 在后台时 transient popover 不会因外部点击关闭.
    @objc
    private func showCalendarFilter() {
        if filterPopover.isShown {
            filterPopover.performClose(nil)
        } else {
            filterPopover.show(relativeTo: calendarsButton.bounds, of: calendarsButton, preferredEdge: .maxY)
        }
    }

    private func persistHidden() {
        defaults.set(hiddenCalendarIDs.sorted(), forKey: Key.hiddenCalendars)
        if let snapshot {
            rebuildCalendarsMenu(snapshot.calendars)
        }
        relayout()
    }
}

/// block observer token 持有者: 随 controller 释放时注销 (MainActor deinit 不能访问隔离状态).
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

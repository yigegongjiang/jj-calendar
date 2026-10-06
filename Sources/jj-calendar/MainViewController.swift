import AppKit
import EventKit

/// 主界面: 起止年月 (可跨年) -> 一屏连续周网格展示区间内全部日程 (不滚动).
final class MainViewController: NSViewController {
    private enum Key {
        /// YearMonth.index.
        static let start = "range.start"
        static let end = "range.end"
        static let hiddenCalendars = "hiddenCalendarIDs"
        static let fontSize = "fontSize"
    }

    private let store = CalendarStore()
    private let defaults = UserDefaults.standard

    private let startYearPopup = SettablePopUpButton()
    private let startMonthPopup = SettablePopUpButton()
    private let endYearPopup = SettablePopUpButton()
    private let endMonthPopup = SettablePopUpButton()
    private let calendarsButton = NSButton(title: "日历", target: nil, action: nil)
    private let filterController = CalendarFilterController()
    private lazy var filterPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = filterController
        return popover
    }()

    private let summaryLabel = NSTextField(labelWithString: "")
    private let gridView = WeekGridView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "打开日历隐私设置", target: nil, action: nil)

    private var calendar = WeekLayout.calendar()
    private var start = YearMonth(year: 2000, month: 1)
    private var end = YearMonth(year: 2000, month: 1)
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
            startYearPopup, startMonthPopup, NSTextField(labelWithString: "–"), endYearPopup, endMonthPopup,
            calendarsButton, summaryLabel
        ])
        toolbar.spacing = 4
        toolbar.setCustomSpacing(12, after: endMonthPopup)
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
        let months = (1...12).map { "\($0)月" }
        startMonthPopup.addItems(withTitles: months)
        endMonthPopup.addItems(withTitles: months)
        syncRangeControls()

        for (popup, id) in [
            (startYearPopup, "startYearPopup"), (startMonthPopup, "startMonthPopup"),
            (endYearPopup, "endYearPopup"), (endMonthPopup, "endMonthPopup")
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
        let savedFont = defaults.object(forKey: Key.fontSize) as? Double
        applyFontSize(savedFont.map { CGFloat($0) } ?? Typography.standard)
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("summaryLabel")
    }

    private var range: MonthRange {
        WeekLayout.range(start: start, end: end, calendar: calendar)
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
                self?.syncRangeControls()
                self?.relayout()
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
        summaryLabel.stringValue = "\(range.months) 个月 · \(inRange) 个日程"
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

// MARK: - Range (起止年月, 可跨年)

extension MainViewController {
    /// 年份候选 = 当前年 ±3 (运行时计算) ∪ 已选年份; 选中项与 start / end 同步.
    private func syncRangeControls() {
        let current = calendar.component(.year, from: Date())
        let years = min(current - 3, start.year)...max(current + 3, end.year)
        for (popup, value) in [(startYearPopup, start), (endYearPopup, end)] {
            popup.removeAllItems()
            popup.addItems(withTitles: years.map { "\($0)年" })
            for (item, year) in zip(popup.itemArray, years) {
                item.tag = year
            }
            popup.selectItem(withTag: value.year)
        }
        startMonthPopup.selectItem(at: start.month - 1)
        endMonthPopup.selectItem(at: end.month - 1)
    }

    private func restoreRange() {
        let now = calendar.dateComponents([.year, .month], from: Date())
        let current = YearMonth(year: now.year!, month: now.month!)
        if let first = defaults.object(forKey: Key.start) as? Int, let last = defaults.object(forKey: Key.end) as? Int,
           first <= last {
            start = YearMonth(index: first)
            end = YearMonth(index: last)
        } else if let year = defaults.object(forKey: "range.year") as? Int,
                  let first = defaults.object(forKey: "range.startMonth") as? Int,
                  let last = defaults.object(forKey: "range.endMonth") as? Int,
                  (1...12).contains(first), (1...12).contains(last) {
            // v0.2.x: 单一年份 + 起止月, 结束月 < 起始月表示跨入次年.
            start = YearMonth(year: year, month: first)
            end = YearMonth(year: last >= first ? year : year + 1, month: last)
        } else {
            start = current
            end = YearMonth(index: current.index + 4)
        }
        for legacy in ["range.year", "range.startMonth", "range.endMonth"] {
            defaults.removeObject(forKey: legacy)
        }
        defaults.set(start.index, forKey: Key.start)
        defaults.set(end.index, forKey: Key.end)
    }

    /// 起止颠倒时移动另一端: 改起点 -> 终点保持原跨度随之后移; 改终点 -> 起点跟随.
    @objc
    private func rangeChanged(_ sender: NSPopUpButton) {
        var newStart = YearMonth(year: startYearPopup.selectedTag(), month: startMonthPopup.indexOfSelectedItem + 1)
        var newEnd = YearMonth(year: endYearPopup.selectedTag(), month: endMonthPopup.indexOfSelectedItem + 1)
        if newStart > newEnd {
            if sender === startYearPopup || sender === startMonthPopup {
                newEnd = YearMonth(index: newStart.index + end.index - start.index)
            } else {
                newStart = newEnd
            }
        }
        start = newStart
        end = newEnd
        defaults.set(start.index, forKey: Key.start)
        defaults.set(end.index, forKey: Key.end)
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

    @objc
    private func showCalendarFilter() {
        filterPopover.show(relativeTo: calendarsButton.bounds, of: calendarsButton, preferredEdge: .maxY)
    }

    private func persistHidden() {
        defaults.set(hiddenCalendarIDs.sorted(), forKey: Key.hiddenCalendars)
        if let snapshot {
            rebuildCalendarsMenu(snapshot.calendars)
        }
        relayout()
    }
}

/// AX value 可写: 自动化以 set value (选项标题) 后台切换, 无需弹出菜单 (弹菜单需前台).
/// NSPopUpButton 的 AX 元素由 cell 提供, 覆写须在 cell 上.
private final class SettablePopUpButton: NSPopUpButton {
    override static var cellClass: AnyClass? {
        get { Cell.self }
        set { _ = newValue }
    }

    private final class Cell: NSPopUpButtonCell {
        override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
            selector == #selector(setAccessibilityValue(_:)) || super.isAccessibilitySelectorAllowed(selector)
        }

        override func setAccessibilityValue(_ value: Any?) {
            guard let title = value as? String, let item = item(withTitle: title),
                  let control = controlView as? NSControl else { return }
            select(item)
            control.sendAction(action, to: target)
        }
    }
}

/// block observer token 持有者: 随 controller 释放时注销 (MainActor deinit 不能访问隔离状态).
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }
}

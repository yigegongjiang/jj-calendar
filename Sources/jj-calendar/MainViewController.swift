import AppKit
import EventKit

/// 主界面: 年份 + 起止月份 -> 一屏连续周网格展示区间内全部日程 (不滚动); 结束月 < 起始月时跨入次年.
final class MainViewController: NSViewController {
    private enum Key {
        static let year = "range.year"
        static let startMonth = "range.startMonth"
        static let endMonth = "range.endMonth"
        static let hiddenCalendars = "hiddenCalendarIDs"
    }

    private let store = CalendarStore()
    private let defaults = UserDefaults.standard

    private let yearPopup = NSPopUpButton()
    private let startPopup = NSPopUpButton()
    private let endPopup = NSPopUpButton()
    private let calendarsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let summaryLabel = NSTextField(labelWithString: "")
    private let gridView = WeekGridView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton(title: "打开日历隐私设置", target: nil, action: nil)

    private var calendar = WeekLayout.calendar()
    private var year = 0
    private var startMonth = 1
    private var endMonth = 1
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
            yearPopup, startPopup, NSTextField(labelWithString: "至"), endPopup, calendarsPopup, summaryLabel
        ])
        toolbar.spacing = 6
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
        startPopup.addItems(withTitles: months)
        endPopup.addItems(withTitles: months)
        rebuildYearPopup()
        startPopup.selectItem(at: startMonth - 1)
        endPopup.selectItem(at: endMonth - 1)

        for (popup, id) in [(yearPopup, "yearPopup"), (startPopup, "startMonthPopup"), (endPopup, "endMonthPopup")] {
            popup.target = self
            popup.action = #selector(rangeChanged)
            popup.setAccessibilityIdentifier(id)
        }
        calendarsPopup.setAccessibilityIdentifier("calendarsPopup")
        calendarsPopup.addItem(withTitle: "日历")
        for popup in [yearPopup, startPopup, endPopup, calendarsPopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        }
        summaryLabel.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("summaryLabel")
    }

    /// 年份候选 = 当前年 ±3 (运行时计算) ∪ 已选年份.
    private func rebuildYearPopup() {
        let current = calendar.component(.year, from: Date())
        let years = min(current - 3, year)...max(current + 3, year)
        yearPopup.removeAllItems()
        yearPopup.addItems(withTitles: years.map { "\($0)年" })
        for (item, value) in zip(yearPopup.itemArray, years) {
            item.tag = value
        }
        yearPopup.selectItem(withTag: year)
    }

    private func restoreRange() {
        let current = calendar.dateComponents([.year, .month], from: Date())
        year = defaults.object(forKey: Key.year) as? Int ?? current.year!
        startMonth = defaults.object(forKey: Key.startMonth) as? Int ?? current.month!
        endMonth = defaults.object(forKey: Key.endMonth) as? Int ?? (current.month! + 4) % 12 + 1
        if !(1...12).contains(startMonth) {
            startMonth = current.month!
        }
        if !(1...12).contains(endMonth) {
            endMonth = startMonth
        }
    }

    @objc
    private func rangeChanged() {
        year = yearPopup.selectedTag()
        startMonth = startPopup.indexOfSelectedItem + 1
        endMonth = endPopup.indexOfSelectedItem + 1
        defaults.set(year, forKey: Key.year)
        defaults.set(startMonth, forKey: Key.startMonth)
        defaults.set(endMonth, forKey: Key.endMonth)
        reload()
    }

    private var range: MonthRange {
        WeekLayout.range(year: year, startMonth: startMonth, endMonth: endMonth, calendar: calendar)
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
                self?.rebuildYearPopup()
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
        let last = calendar.date(byAdding: .month, value: -1, to: range.end)!
        let first = calendar.dateComponents([.year, .month], from: range.start)
        let end = calendar.dateComponents([.year, .month], from: last)
        let span = "\(first.year!)年\(first.month!)月 – \(end.year!)年\(end.month!)月"
        summaryLabel.stringValue = "\(span) · \(range.months) 个月 · \(inRange) 个日程"
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

// MARK: - Calendars filter

extension MainViewController {
    private func rebuildCalendarsMenu(_ calendars: [CalendarSummary]) {
        let menu = calendarsPopup.menu!
        while menu.numberOfItems > 1 {
            menu.removeItem(at: 1)
        }
        let showAll = NSMenuItem(title: "全部显示", action: #selector(showAllCalendars), keyEquivalent: "")
        showAll.target = self
        menu.addItem(showAll)
        let grouped = Dictionary(grouping: calendars, by: \.source).sorted { $0.key < $1.key }
        for (source, items) in grouped {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: source.isEmpty ? "其他" : source))
            for summary in items.sorted(by: { $0.title < $1.title }) {
                let item = NSMenuItem(title: summary.title, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = summary.id
                item.state = hiddenCalendarIDs.contains(summary.id) ? .off : .on
                item.image = Self.swatch(summary.color)
                menu.addItem(item)
            }
        }
        let hidden = calendars.count { hiddenCalendarIDs.contains($0.id) }
        calendarsPopup.item(at: 0)?.title = hidden == 0 ? "日历" : "日历 (隐藏 \(hidden))"
    }

    private static func swatch(_ color: RGBA) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    @objc
    private func toggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if hiddenCalendarIDs.remove(id) == nil {
            hiddenCalendarIDs.insert(id)
        }
        persistHidden()
    }

    @objc
    private func showAllCalendars() {
        hiddenCalendarIDs.removeAll()
        persistHidden()
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

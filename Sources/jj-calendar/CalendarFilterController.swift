import AppKit

/// 日历筛选面板 (popover): 页签 (日历 / 提醒事项) + 搜索 + 分组大纲; 整行点击切换显示, 面板不关闭; 超出可用高度滚动.
/// - 核心操作「只显示」: 悬停行 / ⌥ 点击 / ⌥ 空格 / 右键; 只作用于当前页签; 还原点持久化 (重启后可还原).
///   只显示期间: 页签顶部横幅 (还原 / 保留当前) + 该行常驻「还原」+ 主界面工具栏还原按钮.
/// - 每个页签有整源开关: 关闭 = 主界面不显示该源, 列表勾选保持, 重新打开即恢复.
/// - 分组: 按账户, 「已忽略」置底默认折叠; 页签 + 折叠状态持久化; 分组复选框 = 整组显示 / 隐藏.
/// - 空格 / 回车 = 切换; 搜索框 ↓ 进入列表, 列表首行 ↑ 回搜索框.
/// - 已忽略: 忽略即隐藏并移到底部, 手动勾选才显示 (事件淡化); 取消忽略即显示.
final class CalendarFilterController: NSViewController {
    var onChange: ((FilterSelection) -> Void)?
    /// 面板可用高度; 打开前由 fit(to:) 按锚点位置设置.
    private var maxHeight: CGFloat = 600

    private var calendars: [CalendarSummary] = []
    private(set) var selection = FilterSelection.saved
    private(set) var groups: [FilterGroup] = []
    private var source = FilterSource(rawValue: ConfigStore.state.filterTab) ?? .calendars
    private var collapsed = Set(ConfigStore.state.collapsedCalendarGroups)
    /// reload 时程序化展开不写入折叠状态.
    private var isReloading = false
    private let tabs = NSSegmentedControl(
        labels: FilterSource.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let sourceLabel = NSTextField(labelWithString: "")
    private let sourceSwitch = NSSwitch()
    private let searchField = NSSearchField()
    private let banner = SoloBanner()
    private let top = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    let outline = FilterOutlineView()
    private let scrollView = NSScrollView()
    private static let width: CGFloat = 360

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// 当前页签的全部 id.
    private var scopeIDs: Set<String> {
        scopeIDs(source)
    }

    private func scopeIDs(_ source: FilterSource) -> Set<String> {
        Set(calendars.lazy.filter(source.contains).map(\.id))
    }

    override func loadView() {
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = source.rawValue
        tabs.setAccessibilityIdentifier("calendarsTabs")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        searchField.placeholderString = "搜索日历 / 提醒事项"
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("calendarsSearch")
        banner.onRestore = { [weak self] in self?.restore() }
        banner.onKeep = { [weak self] in self?.keep() }
        for view in [tabs, banner, sourceRow(), searchField] {
            top.addArrangedSubview(view)
        }
        top.orientation = .vertical
        top.alignment = .width
        top.spacing = 8

        configureOutline()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let view = NSView()
        for subview in [top, scrollView, emptyLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            tabs.widthAnchor.constraint(equalTo: top.widthAnchor),
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20)
        ])
        self.view = view
        preferredContentSize = NSSize(width: Self.width, height: 200)
    }

    /// 「在 jj-calendar 中显示…」+ 整源开关.
    private func sourceRow() -> NSStackView {
        sourceSwitch.controlSize = .small
        sourceSwitch.target = self
        sourceSwitch.action = #selector(sourceToggled)
        sourceSwitch.setAccessibilityIdentifier("sourceSwitch")
        sourceLabel.font = .systemFont(ofSize: 12)
        sourceLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        sourceSwitch.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [sourceLabel, sourceSwitch])
        row.distribution = .fill
        return row
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("calendar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowSizeStyle = .custom
        outline.indentationPerLevel = 12
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        outline.setAccessibilityIdentifier("calendarsOutline")
        outline.onToggle = { [weak self] solo in
            guard let self, let node = outline.item(atRow: outline.selectedRow) else { return }
            perform(solo ? .solo : .toggle, on: node)
        }
        outline.onExitTop = { [weak self] in
            guard let self else { return }
            outline.deselectAll(nil)
            view.window?.makeFirstResponder(searchField)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    /// 关闭即清空搜索: 下次打开从完整列表开始.
    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        reload()
    }

    /// 可用高度 = 锚点上下两侧较大的一侧 (NSPopover 放不下时自动翻到另一侧), 扣除箭头 + 边距; 超出部分面板内滚动.
    func fit(to anchor: NSView) {
        guard let window = anchor.window, let screen = window.screen else { return }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let visible = screen.visibleFrame
        maxHeight = max(rect.minY - visible.minY, visible.maxY - rect.maxY) - 40
        updateSize()
    }

    /// 数据刷新 (iCloud 同步等) 时可能正打开: 结构未变只刷新行状态, 保持搜索 / 折叠 / 滚动位置.
    func update(calendars: [CalendarSummary], selection: FilterSelection) {
        _ = view
        let structural = calendars != self.calendars || selection.ignored != self.selection.ignored
        self.calendars = calendars
        self.selection = selection
        if structural {
            reload()
        } else {
            refreshRows()
        }
    }

    func reload() {
        groups = FilterGroup.make(calendars, source: source, ignored: selection.ignored, query: query)
        emptyLabel.stringValue = !query.isEmpty ? "无匹配" : source == .reminders ? "无提醒事项列表 (未授权?)" : "无日历"
        emptyLabel.isHidden = !groups.isEmpty
        isReloading = true
        outline.reloadData()
        for group in groups where !query.isEmpty || !collapsed.contains(group.key) {
            outline.expandItem(group)
        }
        isReloading = false
        updateTabs()
        updateSize()
    }

    /// 整源开关状态; 关闭时列表淡化 (仍可编辑, 重新打开后生效).
    private func updateSourceSwitch() {
        let isOn = !FilterSource.disabled.contains(source)
        sourceSwitch.state = isOn ? .on : .off
        sourceLabel.stringValue = "在 jj-calendar 中显示\(source.title)"
        sourceLabel.textColor = isOn ? .labelColor : .secondaryLabelColor
        sourceSwitch.setAccessibilityLabel(sourceLabel.stringValue)
        sourceSwitch.toolTip = "关闭: 主界面不显示\(source.title); 下方各列表勾选保持不变"
        outline.alphaValue = isOn ? 1 : 0.45
    }

    @objc
    private func sourceToggled() {
        var disabled = FilterSource.disabled
        if disabled.remove(source) == nil {
            disabled.insert(source)
        }
        ConfigStore.update { $0.disabledSources = disabled.map(\.rawValue).sorted() }
        updateTabs()
        onChange?(selection)
    }

    /// 页签标题: 「日历 3/5」(不计已忽略); 只显示中加「· 只显示」; 整源关闭: 「日历 · 关」. 同步横幅.
    private func updateTabs() {
        updateSourceSwitch()
        let disabled = FilterSource.disabled
        for source in FilterSource.allCases {
            guard !disabled.contains(source) else {
                tabs.setLabel("\(source.title) · 关", forSegment: source.rawValue)
                continue
            }
            let active = calendars.filter { source.contains($0) && !selection.ignored.contains($0.id) }
            let shown = active.count { !selection.hidden.contains($0.id) }
            let solo = selection.solo(source) == nil ? "" : " · 只显示"
            tabs.setLabel("\(source.title)  \(shown)/\(active.count)\(solo)", forSegment: source.rawValue)
        }
        updateBanner()
    }

    @objc
    private func tabChanged() {
        guard let source = FilterSource(rawValue: tabs.selectedSegment), source != self.source else { return }
        self.source = source
        ConfigStore.update { $0.filterTab = source.rawValue }
        outline.deselectAll(nil)
        reload()
        outline.scrollRowToVisible(0)
    }

    private func refreshRows() {
        updateTabs()
        outline.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.subviews.lazy.compactMap({ $0 as? FilterCell }).first,
                  let node = outline.item(atRow: row) else { return }
            configure(cell, for: node)
        }
    }

    private func updateSize() {
        guard isViewLoaded else { return }
        // 按行高累加: 刚展开 / 折叠时 rect(ofRow:) 可能尚未更新.
        let rows = (0..<outline.numberOfRows).reduce(0) { total, row in
            total + Self.rowHeight(outline.item(atRow: row)) + outline.intercellSpacing.height
        }
        let header = 10 + top.fittingSize.height + 8
        let height = header + max(rows, 60) + 8
        preferredContentSize = NSSize(width: Self.width, height: min(height, max(maxHeight, 240)))
    }

    func configure(_ cell: FilterCell, for node: Any) {
        if let item = node as? FilterItem {
            let id = item.summary.id
            let isOn = !selection.hidden.contains(id)
            cell.showItem(item.summary, isOn: isOn, isIgnored: item.isIgnored, isSolo: isSoloTarget(id))
        } else if let group = node as? FilterGroup {
            let shown = group.ids.count { !selection.hidden.contains($0) }
            cell.showGroup(group, shown: shown, isSolo: isSoloTarget(group.soloKey))
        }
        cell.onAction = { [weak self] action in
            self?.perform(action, on: node)
        }
    }

    /// 当前页签只显示的对象: 该行常驻「还原」.
    func isSoloTarget(_ key: String) -> Bool {
        selection.solo(source)?.key == key
    }

    func persistCollapsed(_ notification: Notification, collapsed isCollapsed: Bool) {
        guard !isReloading, query.isEmpty,
              let group = notification.userInfo?["NSObject"] as? FilterGroup else { return }
        if isCollapsed {
            collapsed.insert(group.key)
        } else {
            collapsed.remove(group.key)
        }
        ConfigStore.update { [collapsed] in $0.collapsedCalendarGroups = collapsed.sorted() }
        updateSize()
    }
}

// MARK: - Actions

extension CalendarFilterController {
    func perform(_ action: FilterAction, on node: Any) {
        if let item = node as? FilterItem {
            perform(action, on: item)
        } else if let group = node as? FilterGroup {
            perform(action, on: group)
        }
        commit()
    }

    private func perform(_ action: FilterAction, on item: FilterItem) {
        let id = item.summary.id
        switch action {
        case .toggle: selection.hidden.formSymmetricDifference([id])
        case .solo: selection.showOnly([id], key: id, title: item.summary.title, in: source, scope: scopeIDs)
        case .ignore:
            selection.toggleIgnored(id)
            reload()
        case .show, .hide: break
        }
    }

    private func perform(_ action: FilterAction, on group: FilterGroup) {
        let ids = Set(group.ids)
        switch action {
        case .toggle: selection.setVisible(ids, !selection.hidden.isDisjoint(with: ids))
        case .show: selection.setVisible(ids, true)
        case .hide: selection.setVisible(ids, false)
        case .solo: selection.showOnly(ids, key: group.soloKey, title: group.title, in: source, scope: scopeIDs)
        case .ignore: break
        }
    }

    /// 横幅: 只显示的对象 + 还原后恢复几项.
    private func updateBanner() {
        guard let solo = selection.solo(source) else {
            banner.isHidden = true
            return
        }
        let restored = scopeIDs.subtracting(solo.restore).subtracting(selection.ignored).count
        banner.show(title: "只显示「\(solo.title)」", detail: "还原后恢复显示 \(restored) 项")
        banner.isHidden = false
    }

    /// 还原当前页签.
    private func restore() {
        selection.restore(source, scope: scopeIDs)
        commit()
    }

    /// 还原所有页签 (工具栏按钮).
    func restoreAll() {
        for source in FilterSource.allCases {
            selection.restore(source, scope: scopeIDs(source))
        }
        commit()
    }

    private func keep() {
        selection.keep(source)
        commit()
    }

    /// 点击行空白处 / 标题: 条目切换显示 (⌥ = 只显示), 分组展开 / 折叠.
    @objc
    private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) else { return }
        if node is FilterGroup {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
        } else {
            perform(NSEvent.modifierFlags.contains(.option) ? .solo : .toggle, on: node)
        }
    }

    private func commit() {
        refreshRows()
        updateSize()
        onChange?(selection)
    }
}

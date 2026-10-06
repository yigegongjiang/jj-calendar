import AppKit

/// 日历筛选面板 (popover): 页签 (日历 / 提醒事项) + 搜索 + 分组大纲; 整行点击切换显示, 面板不关闭; 超出可用高度滚动.
/// - 两个页签分开控制: 全部显示 / 全部隐藏 / 只显示 只作用于当前页签.
/// - 分组: 按账户, 「已忽略」置底默认折叠; 页签 + 折叠状态持久化.
/// - 分组复选框 = 整组显示 / 隐藏; 悬停 / 选中行显示「只显示」「忽略」; 同项再点「还原」回到只显示前.
/// - ⌥ 点击 / ⌥ 空格 = 只显示; 空格 / 回车 = 切换; 搜索框 ↓ 进入列表, 列表首行 ↑ 回搜索框.
/// - 已忽略: 忽略即隐藏, 不参与全部显示, 手动勾选才显示 (事件淡化); 取消忽略即显示.
final class CalendarFilterController: NSViewController {
    var onChange: ((_ hidden: Set<String>, _ ignored: Set<String>) -> Void)?
    /// 面板可用高度; 打开前由 fit(to:) 按锚点位置设置.
    private var maxHeight: CGFloat = 600

    private var calendars: [CalendarSummary] = []
    private var hidden: Set<String> = []
    private var ignored: Set<String> = []
    private var groups: [FilterGroup] = []
    private var source = FilterSource(rawValue: ConfigStore.state.filterTab) ?? .calendars
    private var collapsed = Set(ConfigStore.state.collapsedCalendarGroups)
    /// 最近一次「只显示」: 同一项再点还原.
    private var solo: (key: String, restore: Set<String>)?
    /// reload 时程序化展开不写入折叠状态.
    private var isReloading = false
    private let tabs = NSSegmentedControl(
        labels: FilterSource.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil
    )
    private let searchField = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    let outline = FilterOutlineView()
    private let scrollView = NSScrollView()
    private static let width: CGFloat = 360
    private static let headerHeight: CGFloat = 78

    private var query: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    /// 当前页签的全部 id.
    private var scopeIDs: Set<String> {
        Set(calendars.lazy.filter(source.contains).map(\.id))
    }

    override func loadView() {
        let showAll = FilterCell.pushButton("全部显示", target: self, action: #selector(showAll))
        let hideAll = FilterCell.pushButton("全部隐藏", target: self, action: #selector(hideAll))
        showAll.setAccessibilityIdentifier("calendarsShowAll")
        hideAll.setAccessibilityIdentifier("calendarsHideAll")
        showAll.toolTip = "显示当前页签全部未忽略的列表"
        hideAll.toolTip = "隐藏当前页签全部列表"
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
        let bar = NSStackView(views: [searchField, showAll, hideAll])
        bar.spacing = 6
        let top = NSStackView(views: [tabs, bar])
        top.orientation = .vertical
        top.alignment = .width
        top.spacing = 8
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20)
        ])
        self.view = view
        preferredContentSize = NSSize(width: Self.width, height: 200)
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
    func update(calendars: [CalendarSummary], hidden: Set<String>, ignored: Set<String>) {
        _ = view
        let structural = calendars != self.calendars || ignored != self.ignored
        self.calendars = calendars
        self.hidden = hidden
        self.ignored = ignored
        if structural {
            reload()
        } else {
            refreshRows()
        }
    }

    func reload() {
        groups = FilterGroup.make(calendars, source: source, ignored: ignored, query: query)
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

    /// 页签标题带显示数: 「日历 3/5」(不计已忽略).
    private func updateTabs() {
        for source in FilterSource.allCases {
            let active = calendars.filter { source.contains($0) && !ignored.contains($0.id) }
            let shown = active.count { !hidden.contains($0.id) }
            tabs.setLabel("\(source.title)  \(shown)/\(active.count)", forSegment: source.rawValue)
        }
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
        let height = Self.headerHeight + max(rows, 60) + 8
        preferredContentSize = NSSize(width: Self.width, height: min(height, max(maxHeight, 240)))
    }

    private func configure(_ cell: FilterCell, for node: Any) {
        if let item = node as? FilterItem {
            let id = item.summary.id
            let isSolo = isSolo(key: id, ids: [id])
            cell.showItem(item.summary, isOn: !hidden.contains(id), isIgnored: item.isIgnored, isSolo: isSolo)
        } else if let group = node as? FilterGroup {
            let shown = group.ids.count { !hidden.contains($0) }
            cell.showGroup(group, shown: shown, isSolo: isSolo(key: group.soloKey, ids: Set(group.ids)))
        }
        cell.onAction = { [weak self] action in
            self?.perform(action, on: node)
        }
    }

    func isSolo(key: String, ids: Set<String>) -> Bool {
        solo?.key == key && scopeIDs.subtracting(hidden) == ids
    }

    private func persistCollapsed(_ notification: Notification, collapsed isCollapsed: Bool) {
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
        case .toggle: hidden.formSymmetricDifference([id])
        case .solo: showOnly(key: id, ids: [id])
        case .ignore: toggleIgnored(id)
        case .show, .hide: break
        }
    }

    private func perform(_ action: FilterAction, on group: FilterGroup) {
        let ids = Set(group.ids)
        switch action {
        case .toggle: setVisible(ids, !hidden.isDisjoint(with: ids))
        case .show: setVisible(ids, true)
        case .hide: setVisible(ids, false)
        case .solo: showOnly(key: group.soloKey, ids: ids)
        case .ignore: break
        }
    }

    private func setVisible(_ ids: Set<String>, _ visible: Bool) {
        if visible {
            hidden.subtract(ids)
        } else {
            hidden.formUnion(ids)
        }
    }

    /// 当前页签内只显示 ids (另一页签不变); 已处于该状态 -> 还原到只显示前.
    private func showOnly(key: String, ids: Set<String>) {
        if let solo, isSolo(key: key, ids: ids) {
            // 只还原当前页签: 期间另一页签的改动保留.
            hidden = hidden.subtracting(scopeIDs).union(solo.restore.intersection(scopeIDs))
            self.solo = nil
        } else {
            solo = (key, hidden)
            hidden = hidden.subtracting(scopeIDs).union(scopeIDs.subtracting(ids))
        }
    }

    /// 忽略即隐藏; 取消忽略即显示.
    private func toggleIgnored(_ id: String) {
        if ignored.remove(id) == nil {
            ignored.insert(id)
            hidden.insert(id)
        } else {
            hidden.remove(id)
        }
        reload()
    }

    /// 当前页签: 只勾选未忽略的; 已忽略的保持原状态.
    @objc
    private func showAll() {
        hidden.subtract(scopeIDs.subtracting(ignored))
        commit()
    }

    @objc
    private func hideAll() {
        hidden.formUnion(scopeIDs)
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
        onChange?(hidden, ignored)
    }
}

// MARK: - Outline

extension CalendarFilterController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groups.count }
        return (item as? FilterGroup)?.items.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let group = item as? FilterGroup else { return groups[index] }
        return group.items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FilterGroup
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        Self.rowHeight(item)
    }

    static func rowHeight(_ item: Any?) -> CGFloat {
        item is FilterGroup ? 26 : 24
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FilterRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let kind: FilterCell.Kind = item is FilterGroup ? .group : .item
        let cell = outlineView.makeView(withIdentifier: kind.identifier, owner: nil) as? FilterCell ?? FilterCell(kind)
        configure(cell, for: item)
        return cell
    }

    /// 鼠标点击不选中 (点击即切换, 选中高亮多余); 键盘导航选中.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        NSApp.currentEvent?.type != .leftMouseDown
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        persistCollapsed(notification, collapsed: false)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        persistCollapsed(notification, collapsed: true)
    }
}

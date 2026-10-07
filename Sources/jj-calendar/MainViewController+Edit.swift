import AppKit

// MARK: - Edit (快速录入 / 微调; 其余字段去系统 App)

extension MainViewController {
    func configureEditing() {
        newItemButton.setAccessibilityIdentifier("newItemButton")
        newItemButton.toolTip = "新建日程 / 提醒 (⌘N); 双击日期格也可新建"
        newItemButton.target = self
        newItemButton.action = #selector(newItem(_:))
        newItemButton.controlSize = .small
        newItemButton.bezelStyle = .push
        newItemButton.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))

        gridView.onEditItem = { [weak self] item, rect, view in
            self?.presentEditor(item: item, isReminder: item.isReminder, day: item.start, rect: rect, of: view)
        }
        gridView.onCreateItem = { [weak self] day, isReminder, rect, view in
            self?.presentEditor(item: nil, isReminder: isReminder, day: day, rect: rect, of: view)
        }
        gridView.onToggleCompleted = { [weak self] item, done in
            guard let self else { return }
            try await store.setCompleted(item, done)
            reload()
        }
        itemEditor.onSave = { [weak self] draft, item in
            guard let self else { return }
            try await store.save(draft, editing: item)
            ConfigStore.update {
                if draft.isReminder {
                    $0.lastReminderListID = draft.calendarID
                } else {
                    $0.lastEventCalendarID = draft.calendarID
                }
            }
            reload()
        }
        itemEditor.onDelete = { [weak self] item in
            guard let self else { return }
            try await store.remove(item)
            reload()
        }
        itemEditor.onClose = { [weak self] in
            self?.editorPopover.performClose(nil)
        }
    }

    /// 标题栏「新建」/ ⌘N: 默认今天, 锚定按钮.
    @objc
    func newItem(_: Any?) {
        presentEditor(item: nil, isReminder: false, day: Date(), rect: newItemButton.bounds, of: newItemButton)
    }

    /// 候选 = 筛选中正在显示 (未隐藏 / 未忽略 / 整源开启) 的可写日历 + 编辑条目自身所属; 只读筛选状态, 不改动.
    /// 新建默认容器: 上次保存所用 -> 系统默认 -> 首个候选.
    private func presentEditor(item: CalendarEvent?, isReminder: Bool, day: Date, rect: NSRect, of view: NSView) {
        guard let snapshot, view.window != nil else { return }
        let disabled = FilterSource.disabled
        let writable = snapshot.calendars.filter { summary in
            summary.isWritable && (summary.id == item?.calendarID || !selection.hidden.contains(summary.id)
                && !selection.ignored.contains(summary.id)
                && !disabled.contains(FilterSource(isReminder: summary.isReminderList)))
        }
        func preferred(_ ids: String?...) -> String? {
            ids.compactMap(\.self).first { id in writable.contains { $0.id == id } }
        }
        let state = ConfigStore.state
        itemEditor.load(ItemEditorController.Request(
            item: item, isReminder: isReminder, day: day, calendars: writable,
            defaultEventCalendarID: preferred(state.lastEventCalendarID, snapshot.defaultEventCalendarID),
            defaultReminderListID: preferred(state.lastReminderListID, snapshot.defaultReminderListID)
        ))
        // 标题栏按钮: 向下弹进窗口 (NSButton 为 flipped 坐标, 下边 = maxY); 日期格: 右侧.
        let below: NSRectEdge = view.isFlipped ? .maxY : .minY
        editorPopover.show(relativeTo: rect, of: view, preferredEdge: view === newItemButton ? below : .maxX)
    }
}

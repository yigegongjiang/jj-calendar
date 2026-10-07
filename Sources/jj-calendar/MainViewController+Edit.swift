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

    /// 新建默认容器: 上次保存所用 -> 系统默认 -> 首个可写.
    private func presentEditor(item: CalendarEvent?, isReminder: Bool, day: Date, rect: NSRect, of view: NSView) {
        guard let snapshot, view.window != nil else { return }
        let writable = snapshot.calendars.filter(\.isWritable)
        func preferred(_ ids: String?...) -> String? {
            ids.compactMap(\.self).first { id in writable.contains { $0.id == id } }
        }
        let state = ConfigStore.state
        itemEditor.load(ItemEditorController.Request(
            item: item, isReminder: isReminder, day: day, calendars: writable,
            defaultEventCalendarID: preferred(state.lastEventCalendarID, snapshot.defaultEventCalendarID),
            defaultReminderListID: preferred(state.lastReminderListID, snapshot.defaultReminderListID)
        ))
        editorPopover.show(relativeTo: rect, of: view, preferredEdge: view === newItemButton ? .minY : .maxX)
    }
}

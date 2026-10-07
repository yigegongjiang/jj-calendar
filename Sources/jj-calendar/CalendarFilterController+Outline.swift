import AppKit

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

// MARK: - Search / context menu

extension CalendarFilterController: NSSearchFieldDelegate, NSMenuDelegate {
    func controlTextDidChange(_ obj: Notification) {
        reload()
    }

    /// ↓ / 回车: 进入列表并选中首个条目.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.moveDown(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let first = (0..<outline.numberOfRows).first { outline.item(atRow: $0) is FilterItem } ?? 0
        guard outline.numberOfRows > 0 else { return true }
        view.window?.makeFirstResponder(outline)
        outline.selectRowIndexes([first], byExtendingSelection: false)
        outline.scrollRowToVisible(first)
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) else { return }
        var entries: [(String, FilterAction)] = []
        if let item = node as? FilterItem {
            let id = item.summary.id
            entries = [
                (isSoloTarget(id) ? "还原" : "只显示「\(item.summary.title)」", .solo),
                (item.isIgnored ? "取消忽略" : "忽略 (隐藏并移到底部)", .ignore)
            ]
        } else if let group = node as? FilterGroup {
            entries = [
                (isSoloTarget(group.soloKey) ? "还原" : "只显示本组", .solo),
                ("显示本组全部", .show),
                ("隐藏本组全部", .hide)
            ]
        }
        for (title, action) in entries {
            let menuItem = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = MenuTarget(node: node, action: action)
            menu.addItem(menuItem)
        }
    }

    @objc
    private func menuAction(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? MenuTarget else { return }
        perform(target.action, on: target.node)
    }
}

private final class MenuTarget: NSObject {
    let node: Any
    let action: FilterAction

    init(node: Any, action: FilterAction) {
        self.node = node
        self.action = action
    }
}

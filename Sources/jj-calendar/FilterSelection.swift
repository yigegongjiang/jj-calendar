import Foundation

/// 「只显示」还原点 (每个页签至多一个): 首次只显示前该页签的隐藏集; 期间再只显示其他项 / 手动勾选不覆盖.
struct SoloRecord: Codable, Equatable {
    /// FilterSource.rawValue.
    var source: Int
    /// 列表 id 或分组 soloKey: 该行显示「还原」.
    var key: String
    var title: String
    /// 只显示前该页签内被隐藏的 id.
    var restore: [String]
}

/// 筛选状态: 隐藏 / 忽略 / 还原点; 整体持久化到 state.json, 重启后仍可还原.
struct FilterSelection: Equatable {
    var hidden: Set<String>
    var ignored: Set<String>
    var solos: [SoloRecord]

    @MainActor static var saved: FilterSelection {
        let state = ConfigStore.state
        return FilterSelection(
            hidden: Set(state.hiddenCalendarIDs), ignored: Set(state.ignoredCalendarIDs), solos: state.solos
        )
    }

    @MainActor
    func save() {
        ConfigStore.update {
            $0.hiddenCalendarIDs = hidden.sorted()
            $0.ignoredCalendarIDs = ignored.sorted()
            $0.solos = solos.sorted { $0.source < $1.source }
        }
    }

    func solo(_ source: FilterSource) -> SoloRecord? {
        solos.first { $0.source == source.rawValue }
    }

    /// 页签内只显示 ids (另一页签不变); 已有还原点则保留最初的; 再点同一项 = 还原.
    mutating func showOnly(_ ids: Set<String>, key: String, title: String, in source: FilterSource,
                           scope: Set<String>) {
        if solo(source)?.key == key {
            restore(source, scope: scope)
            return
        }
        let restore = solo(source)?.restore ?? hidden.intersection(scope).sorted()
        solos.removeAll { $0.source == source.rawValue }
        solos.append(SoloRecord(source: source.rawValue, key: key, title: title, restore: restore))
        hidden = hidden.subtracting(scope).union(scope.subtracting(ids))
    }

    /// 回到只显示前; 只动该页签 (scope), 期间新增的列表保持显示. scope 为空 (数据未载入) 时不动, 保留还原点.
    mutating func restore(_ source: FilterSource, scope: Set<String>) {
        guard let solo = solo(source), !scope.isEmpty else { return }
        hidden = hidden.subtracting(scope).union(Set(solo.restore).intersection(scope))
        solos.removeAll { $0.source == source.rawValue }
    }

    /// 保留当前显示, 丢弃还原点.
    mutating func keep(_ source: FilterSource) {
        solos.removeAll { $0.source == source.rawValue }
    }

    mutating func setVisible(_ ids: Set<String>, _ visible: Bool) {
        if visible {
            hidden.subtract(ids)
        } else {
            hidden.formUnion(ids)
        }
    }

    /// 忽略即隐藏; 取消忽略即显示.
    mutating func toggleIgnored(_ id: String) {
        if ignored.remove(id) == nil {
            ignored.insert(id)
            hidden.insert(id)
        } else {
            hidden.remove(id)
        }
    }
}

/// 筛选面板的数据源页签: 日历 / 提醒事项分开控制.
enum FilterSource: Int, CaseIterable {
    case calendars, reminders

    var title: String {
        self == .calendars ? "日历" : "提醒事项"
    }

    var shortTitle: String {
        self == .calendars ? "日历" : "提醒"
    }

    /// 整源开关: 关闭的源主界面不显示, 各列表勾选状态不变.
    @MainActor static var disabled: Set<FilterSource> {
        Set(ConfigStore.state.disabledSources.compactMap(FilterSource.init(rawValue:)))
    }

    init(isReminder: Bool) {
        self = isReminder ? .reminders : .calendars
    }

    func contains(_ summary: CalendarSummary) -> Bool {
        summary.isReminderList == (self == .reminders)
    }

    /// 工具栏按钮标题: 关闭的源标「关」, 只显示中标对象; 隐藏数只计其余开启源中未忽略的列表.
    @MainActor
    static func buttonTitle(_ calendars: [CalendarSummary], _ selection: FilterSelection) -> String {
        let off = disabled
        let names = allCases.map { source in
            if off.contains(source) {
                return "\(source.shortTitle) 关"
            }
            guard let solo = selection.solo(source) else { return source.shortTitle }
            let title = solo.title.count > 10 ? solo.title.prefix(9) + "…" : solo.title
            return "\(source.shortTitle)「\(title)」"
        }
        let count = calendars.count {
            let source = FilterSource(isReminder: $0.isReminderList)
            return !off.contains(source) && selection.solo(source) == nil && selection.hidden.contains($0.id)
                && !selection.ignored.contains($0.id)
        }
        let joined = names.joined(separator: " · ")
        return count == 0 ? "\(joined) ▾" : "\(joined) (隐藏 \(count)) ▾"
    }
}

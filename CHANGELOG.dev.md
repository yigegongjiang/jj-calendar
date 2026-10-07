```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

## [0.7.2] - 2026-10-07

### Changed

- 新建 / 编辑时的日历 / 列表候选只显示筛选中正在显示的那些, 已隐藏 / 忽略的不再出现
  - `presentEditor`: 候选 = 可写 && (条目自身所属 || 未隐藏 && 未忽略 && 整源开启); README 加截图 `docs/screenshots/`

### Fixed

- 标题栏「新建」弹窗改为向下展开, 不再弹到窗口外
  - NSButton 为 flipped 坐标: 下边 = `.maxY`; 按 `view.isFlipped` 取边

## [0.7.1] - 2026-10-07

### Added

- 菜单新增「About jj-calendar」: 查看当前版本号
  - App 菜单首项 -> `NSApplication.orderFrontStandardAboutPanel(_:)`, 版本取 `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`

## [0.7.0] - 2026-10-07

### Added

- 快速录入: 标题栏「新建」/ ⌘N / 双击日期格空白, 新建日程或提醒 (标题 / 日历 / 全天 / 时间)
  - `ItemEditorController` (popover) + `MainViewController+Edit`; File 菜单 ⌘N; `WeekRowView.mouseDown` clickCount 2 -> `onCreate`
  - 有时刻的提醒: 截止时刻变化时同步移动 / 补 `EKAlarm(absoluteDate:)`
- 快速微调: 双击条目或当日列表「编辑」, 可改标题 / 日历 / 时间, 或删除 (二次确认); 重复日程只改本次
  - `CalendarStore+Write`: 按 `calendarItemIdentifier` + `occurrenceDate` 重新取目标, `save/remove(span: .thisEvent, commit: true)`
  - Debug 构建 `checkWritable` 限测试白名单 (iCloud 账户下精确标题); 重复提醒无 span, 作用于整个系列 (编辑器提示)
- 当日列表: 「+日程 / +提醒」在当日新建; 提醒前的勾选框直接完成 / 取消完成
  - `DayDetailController` 拆出独立文件; `ClosureButton`; 完成失败回滚勾选 + 红字提示
- 只读日历 (订阅 / 节假日 / 生日) 与他人组织的会议不提供编辑入口; 新建默认沿用上次所选日历 / 列表
  - `CalendarEvent.isWritable` = `allowsContentModifications` && (无参与人 || 组织者为本人); `state.json` `lastEventCalendarID` / `lastReminderListID`
  - AX: 日期格自定义动作「新建日程 / 新建提醒」, 可写条目「编辑」

## [0.6.2] - 2026-10-07

### Added

- 菜单新增「Settings…」(⌘,): 在 Finder 中打开配置文件夹
  - `AppDelegate.openConfigFolder`: `NSWorkspace.open(ConfigStore.directory)`; Debug 实例 `activates = false`

## [0.6.1] - 2026-10-07

### Fixed

- 筛选面板「只显示」改为每行常驻, 所有行在右侧同一列对齐, 不再随标题长度左右漂移; 悬停时加边框
  - 根因: 条目复选框 hugging 高于单元格宽度约束, 单元格按内容收缩; 复选框 hugging 降为 1; `soloButton` 固定宽 66
  - `setRevealed`: 平时无边框淡色文字, 悬停 / 选中 `isBordered`; 分组计数移到「只显示」左侧常驻
- 「忽略」移到「只显示」左侧, 仍是悬停才出现
  - actions 顺序 `[ignoreButton, soloButton]`, `ignoreButton` 固定宽 70

## [0.6.0] - 2026-10-07

### Changed

- 「只显示」成为筛选面板的核心操作; 移除「全部显示 / 全部隐藏」
  - 删除 `showAll` / `hideAll`; 筛选状态收敛为 `FilterSelection` (hidden / ignored / solos), 面板与主界面共享
- 只显示中: 页签顶部横幅显示对象和「还原 / 保留当前」, 该行常驻「还原」, 页签标「只显示」
  - `SoloBanner` (AX `soloBanner` / `soloRestore` / `soloKeep`); `FilterCell.setSolo` 强调色常驻; 面板高度按 `top.fittingSize` 动态
- 主界面工具栏新增「还原」按钮 (只显示中才出现), 筛选按钮标出只显示的对象 (如「日历「个人」」)
  - `soloRestoreButton` -> `restoreAll()`; 筛选相关移到 `MainViewController+Filter.swift`; `FilterSource.buttonTitle(_:_:)`
- 还原点重启后保留; 连续只显示多个对象时, 还原回到第一次只显示之前
  - `AppState.solos: [SoloRecord]` (每页签一个, restore = 该页签只显示前的隐藏集); 数据未载入时不还原, 保留记录

## [0.5.3] - 2026-10-07

### Added

- 筛选面板每个页签新增「在 jj-calendar 中显示日历 / 提醒事项」开关: 一键关闭或恢复整个来源, 各列表的勾选保持不变
  - `AppState.disabledSources`; `FilterSource.disabled` 在 `relayout` 过滤; NSSwitch AX id `sourceSwitch`; 关闭时列表淡化仍可编辑
- 关闭的来源在按钮上标「关」(如「日历 关 · 提醒」), 摘要只统计开启的来源
  - `FilterSource.buttonTitle`; `EventText.summary(sources:)`; 大纲 / 搜索菜单扩展拆到 `CalendarFilterController+Outline.swift`

## [0.5.2] - 2026-10-06

### Changed

- 打版本标签后自动发布 GitHub Release
  - `.github/workflows/release.yml`: on push tags `v*`; 保留 `workflow_dispatch` 重跑

## [0.5.1] - 2026-10-06

### Fixed

- 长区间 (如 2 年 + 每行两周) 滚动卡顿: 首次滚动不再掉帧到个位数帧率, 滚动全程流畅
  - 根因: 每格 / 每条一个 NSView (24 个月两周 2466 个); AppKit 首次滚动每帧重绘全部 chip (~1655 次文字排版 / 帧, 146 ms), 之后每帧图层遍历仍 12–16 ms
  - `WeekRowView` 无子视图: `wantsUpdateLayer` + `layer.contents` = 整行位图; `RowPicture` 后台 `Task.detached` 渲染, generation 作废旧结果; 可见且无位图 (含内容变化) 才同步渲染
  - `DayCellView` / `EventChipView` / `MoreChipView` -> `DayCellArt` / `ChipArt` / `MoreArt`; AX = `NSAccessibilityElement` 虚拟子元素 (可按下); tooltip = `addToolTip` + `NSViewToolTipOwner`
  - `WeekGridView.updateLiveRows`: 视口 ±半屏持有位图, 其余释放; 系统颜色变化重绘; 每帧主线程 146 ms -> 0.6 ms (max 1.2 ms)

## [0.5.0] - 2026-10-06

### Changed

- 日历筛选面板重做: 「日历 / 提醒事项」分页签独立控制, 全部显示 / 隐藏 / 只显示只影响当前页签
  - `CalendarFilterController`: NSGridView -> NSOutlineView (FilterGroup / FilterItem); `FilterSource` 页签, 操作作用域 = `scopeIDs`
- 按账户分组, 分组复选框一键整组显示 / 隐藏; 顶部搜索框, 打开即可输入
  - 分组三态复选框; 搜索匹配标题 / 账户名, 关闭面板清空; 结构未变只刷新可见行 (iCloud 刷新不跳动)
- 整行点击切换; 「只显示」「忽略」悬停才出现, 同项再点「还原」回到之前状态; 右键菜单同样可用
  - `FilterRowView` 追踪悬停; 按钮仅切 alpha 保留 AX 节点 (`only:<id>` / `ignore:<id>`); `solo` 记录还原点; 取消忽略即显示
- 「已忽略」默认折叠; 面板高度不超出屏幕, 列表过长时滚动
  - `AppState.filterTab` / `collapsedCalendarGroups`; `fit(to:)` 按按钮上下较大一侧计算最大高度
- 键盘: ↓ 进入列表, 空格 / 回车切换, ⌥ 空格只显示
  - `FilterOutlineView.keyDown`; 鼠标点击不选中行 (`shouldSelectItem`)

## [0.4.3] - 2026-10-06

### Fixed

- 点击无日程的日期不再弹出当日列表 (有弹窗时则关闭)
  - `WeekGridView.toggleDay`: `items.isEmpty` -> 关闭已开 popover, 不再 show

## [0.4.2] - 2026-10-06

### Fixed

- 1 日标签 `-` 两侧加空格 (`2027 - 01 - 01`); 标签上方留白加大
  - `DayCellView.draw`: 格式 `%04d - %02d - 01`, 标签 topPad 1pt; `Typography.header` +1

## [0.4.1] - 2026-10-06

### Fixed

- 1 日标签仅区间首月 / 每年 1 月带年份 (`2027-01-01`), 其余为 `02-01`; 标签左右留白加大
  - `DayInfo.showsYear` (区间首日 / 1 月 1 日) + `DayCellView.draw` 标签 padding 3 -> 5

## [0.4.0] - 2026-10-06

### Added

- 接入提醒事项 (只读): 有截止日期的提醒显示在对应日期, 圆圈 = 未完成, 实心 + 删除线 = 已完成; 逾期标红; 提醒列表在「日历」面板中同样可隐藏 / 忽略
  - `CalendarStore`: `requestFullAccessToReminders` 独立授权; 未完成 = `predicateForIncompleteReminders(nil..end)`, 已完成 = `predicateForCompletedReminders(start..end)`; `dueDateComponents` -> 无时刻 = 全天 [0 点, 次日 0 点)
  - `CalendarEvent.isReminder / isCompleted / isOverdue(now:)`; `CalendarSummary.isReminderList` -> 筛选面板「提醒事项 · 账户」分组; `INFOPLIST_KEY_NSRemindersFullAccessUsageDescription`
  - `AccessState` 记录授权; 激活时状态变化 -> 重新读取 (+ `store.reset()`); 缺一侧 -> 工具栏 `accessButton` 直达对应隐私设置
- 工具栏显示「N 个日程 · M 个提醒 · 逾期 K」, 悬停列出全部逾期提醒 (含所选区间之前的)
  - `EventText.summary`
- 点击任一日期 / 日程 / 提醒: 弹出当日完整列表 (时间 / 日历 / 地点 / 完成状态), 文字可选中复制; 再点同一天关闭
  - `DayDetailController` (popover, 锚定 `DayCellView`); 点击走响应链到 `WeekRowView.mouseDown`; 日期格 / chip / +N 均支持 `accessibilityPerformPress`; 数据刷新时原地更新或关闭

### Changed

- 某天放不下时, 该天最后一行显示醒目的「+N 项」, 点击查看当天全部; 不再只在日期角落标小字
  - `WeekRowView.apply`: 每列独立, 超容量 -> 可见行 = 容量 - 1 + `MoreChipView`; 横条按列切段, 只画在有空间的列
- 长区间 (1–2 年) 打开 / 切换更快: 先画可见部分, 其余在后台补齐; 日历同步刷新时未变化的周不重绘
  - `WeekGridView`: 视口 ±1 屏的行同步 apply, 其余每批 6 行 + `Task.sleep(1ms)` 让出主线程; 滚动时补建可见行; `WeekRow` / `CalendarEvent` `Equatable` 代替 generation (24 个月 gridLayout 77 ms -> 22 ms, -O)

## [0.3.13] - 2026-10-06

### Changed

- 每月 1 日标签改为 `2027-01-01` 格式 (每月均带年份)
  - `DayCellView.draw`: 1 日文本 `String(format: "%04d-%02d-01", year, month)`

## [0.3.12] - 2026-10-06

### Fixed

- 无标题日程不再显示「(无标题)」, 标题按系统日历原样显示 (含空格)
  - `CalendarStore.snapshot`: `title` 直接取 `event.title ?? ""`, 去掉 trim + 占位

## [0.3.11] - 2026-10-06

### Fixed

- 点「忽略」的日历立即隐藏, 不再以淡色继续显示日程; 想看时在「已忽略」里手动勾选
  - `CalendarFilterController.toggleIgnored`: 加入 `ignored` 时同时 `hidden.insert`

## [0.3.10] - 2026-10-06

### Removed

- 去掉月份交界的阶梯折线 (干扰查看日程); 只保留每月 1 日的强调色实心标签
  - 删 `DayInfo.monthEdgeTop` / `monthEdgeLeading` + `DayCellView.drawMonthEdges`

## [0.3.9] - 2026-10-06

### Fixed

- 「全部隐藏」/「只显示」同时隐藏已忽略的日历, 不再残留其日程; 「全部显示」仍不勾选已忽略的日历
  - `CalendarFilterController.hideAll` / `showOnly` 作用于全部日历; `showAll` 仍排除 `ignored`

## [0.3.8] - 2026-10-06

### Changed

- 月份交界更醒目: 新月份与上月之间画一条粗的强调色阶梯折线; 每月 1 日改为强调色实心标签「N月1日」, 1 月 1 日带年份
  - `DayInfo.monthEdgeTop` (上方格属上月) / `monthEdgeLeading` (1 日且非行首); `DayCellView.drawMonthEdges` 3pt `controlAccentColor`

## [0.3.7] - 2026-10-06

### Changed

- 月与月首尾衔接: 下月 1 日紧接上月末日排在同一行, 不再另起一行; 只在所选区间首日前、末日后留空
  - `WeekLayout.rows()`: 列 = (区间首日星期列 + 日序号) % columns, 仅列回到 0 时换行

## [0.3.6] - 2026-10-06

### Changed

- 列固定为星期 (周一起, 周六 / 周日在最后), 恢复顶部星期表头 (周末红色), 滚动时表头不动; 每月仍新起一行, 1 日落在它的星期列, 前后留空
  - `WeekLayout.calendar()` 固定 `firstWeekday = 2`; `rows()` 按 (1 日星期列 + 日 - 1) % columns 切行; `WeekRow.offset` 由 `WeekRowView.layout` 统一右移
  - `WeekdayHeaderView` 置于 `NSScrollView` 之上, 与行同宽; `DayCellView` 删格内星期, 月首行 1 日补左边线

## [0.3.5] - 2026-10-06

### Changed

- 时长 / 每行天数 / 字号 / 忽略背景色 改存 `~/.config/jj-calendar/config.jsonc`, 带中文说明, 可手工修改 (重启生效)
  - `AppConfig` = 界面选项, 操作时整文件重写 (带 `configNotes`); `AppState` 只剩隐藏 / 忽略日历 + 窗口; 两份文件共用 `PersistedFile`

### Removed

- 去掉 0.3.3 的颜色 / 不透明度配置: 颜色跟随系统日历
  - 删 `AppConfig.appearance` / `layout` / `NSColor(hex:)`; 恢复固定常量

## [0.3.4] - 2026-10-06

### Added

- 日历筛选面板新增「忽略」: 被忽略的日历移到底部「已忽略」组并淡化, 全部显示 / 全部隐藏 / 只显示不再改动它们; 其日程在日历中淡化且排在同格最后
  - `AppState.ignoredCalendarIDs` 持久化; `CalendarEvent.isIgnored` 在 `relayout` 标记; `WeekLayout` 排序置后; 不透明度 `appearance.ignoredOpacity` (默认 0.3); 「隐藏 N」不计已忽略

## [0.3.3] - 2026-10-06

### Added

- 新增 `~/.config/jj-calendar/config.jsonc`: 可自定义隔月背景色 / 强度、今天 / 周末 / +N 颜色、横条与已结束日程不透明度、滚动阈值; 改后重启生效
  - `AppConfig` (appearance / layout) JSON5 解析 + 默认值合并 + `normalized()`; `config.default.jsonc` 启动刷新; `AppConfig.current` 启动读取一次

## [0.3.2] - 2026-10-06

### Changed

- 设置 (时长 / 每行天数 / 字号 / 忽略背景色 / 隐藏日历 / 窗口位置) 改存 `~/.config/jj-calendar/state.json`
  - 新增 `ConfigStore` + `AppState`; 删全部 `UserDefaults` / `setFrameAutosaveName`; 缺失键合并默认值, 解析失败停写 + `window.subtitle` 提示; Debug 用 `.app` 同级 `debug-config/`

## [0.3.1] - 2026-10-06

### Removed

- 去掉「一月」, 每行天数只保留「一周 / 两周」; 之前选了一月的自动改为一周
  - 删 `RowSpan.month`; 读取 `rowSpan` 越界 (旧值 2) 回退 `.week`

## [0.3.0] - 2026-10-06

### Added

- 标题栏右侧新增「一周 / 两周 / 一月」: 选择每行展示的天数, 设置自动记住; 一月模式各月同一日上下对齐
  - `RowSpan` (columns 7 / 14 / 31) + `NSSegmentedControl` `rowSpanControl`; key `rowSpan`

### Changed

- 固定单栏, 不再左右分栏; 每月 1 日总在行首, 月末不足一行留空
  - `WeekLayout.build(span:)` 按月切行, 行内列数可变; 删 `grid(for:)`, 读取区间 = 月份区间; 删多栏 `GridPlan` 候选
- 内容拥挤 (每行放不下 3 条日程) 时改为完整展示 + 上下滚动; 不拥挤时铺满窗口, 无滚动条与回弹
  - `WeekMetrics.minLinesBeforeScroll = 3`; `WeekGridView` 内置 `NSScrollView`, 不滚动时 `verticalScrollElasticity = .none`; 起始日 / 模式变化回顶
- 星期改显示在每个日期格内 (周末红色), 去掉顶部星期表头; 窄格只显示日程标题, +N 优先显示
  - 删 `WeekdayHeaderView`; `DayCellView` 画星期 + `drawMore`; `EventChipView.compactWidth` 以下用 `titleText`

## [0.2.10] - 2026-10-06

### Changed

- 日历筛选面板: 「仅」改为带边框的「只显示」按钮, 「全部显示 / 全部隐藏」恢复为按钮外观, 一眼可辨可点击
  - `CalendarFilterController.pushButton`: 无边框文字按钮 -> `.push` bezel (`.small` / 行内 `.mini`)

## [0.2.9] - 2026-10-06

### Changed

- 日历筛选面板重新排版: 复选框改用日历颜色, 字号与间距更紧凑, 「仅」统一靠右, 长名称截断不再错位; 隐藏的日历名称变灰
  - `CalendarFilterController`: 根视图改为四边钉死的两列 `NSGridView` + 日历色自绘方框 (`image` / `alternateImage`, 对勾按亮度取黑 / 白); 顶部 / 「仅」改无边框文字按钮

## [0.2.8] - 2026-10-06

### Added

- 时长新增「2 年」, 作为最后一档
  - `MainViewController.durations` 追加 `(24, "2 年")`; 网格跨度仍 < EventKit 4 年上限

## [0.2.7] - 2026-10-06

### Changed

- 区间改为「起始年月 + 时长」: 起始默认本月, 时长可选 1 个月 / 3 个月 / 半年 / 9 个月 / 1 年 / 1 年 3 个月 / 1 年半 / 1 年 9 个月, 默认 3 个月; 去掉结束年月选择
  - `MainViewController`: `end` + 结束 popup -> `months` + `durationPopup`; 起始月不持久化, 跨月跟随本月 (`followCurrentMonth`); 仅持久化 `range.months`, 删旧 `range.start` / `range.end`

## [0.2.6] - 2026-10-06

### Changed

- 去掉左侧月份列, 日期区更宽; 每月 1 日加粗显示「N月1日」(周末也不变灰) 区分月份
  - 删 `WeekMetrics.gutter` + `WeekRowView.draw` + `isColumnTop`; `DayCellView` 1 日周末用 `labelColor`

## [0.2.5] - 2026-10-06

### Added

- 标题栏右侧新增「忽略背景色」开关: 关闭月份交替底色, 设置自动记住
  - `NSTitlebarAccessoryViewController` (.trailing) + stack 作为后续按钮容器; UserDefaults `ignoreMonthTint`; `WeekRowView.Config.monthTint`

### Removed

- 月份分界线 (月份已由交替底色区分)
  - 删 `DayCellView.draw` 的 tertiaryLabelColor 阶梯线; `SettablePopUpButton` 拆为独立文件 (file_length)

## [0.2.4] - 2026-10-06

### Added

- 日历筛选每项新增「仅」按钮: 一键只显示该日历 (⌥ 点击仍可用)
  - 只显示 = 可 AX 后台点击的按钮 (修饰键点击需前台); CalendarFilterController.showOnly

### Changed

- 再点「日历」按钮关闭筛选面板
  - 后台时 transient popover 不随外部点击关闭 -> 按钮 toggle
  - Debug 实例窗口 orderBack + 不激活: 启动不遮挡 / 不打断人类

## [0.2.3] - 2026-10-06

### Changed

- 跟随版本同步发布
  - 年 / 月 popup AX value 可写 (SettablePopUpButton cell 覆写 setAccessibilityValue), 自动化后台切换区间, 无需弹菜单

## [0.2.2] - 2026-10-06

### Changed

- 时间选择改为起止「年 + 月」, 可任意跨年 (如 2026年3月 – 2027年10月), 不再限 12 个月
  - YearMonth (index 比较); WeekLayout.range(start:end:); UserDefaults range.start / range.end, 一次性迁移 v0.2.x range.year/startMonth/endMonth
- 字号只用快捷键 ⌘+ / ⌘- / ⌘0, 顶栏移除字号按钮与数字
  - 菜单 ⌘+ 可见 + 隐藏 ⌘= 别名 (allowsKeyEquivalentWhenHidden); target 直连 MainViewController, 后台 AX 可调用
- 月份分界线 / 栏间线改为 1px 暗色细线, 不再刺眼
  - labelColor 0.55–0.6 × 2px → tertiaryLabelColor × 1px

## [0.2.1] - 2026-10-06

### Added

- 字号可调: 顶栏 A− / A+ 或 ⌘- / ⌘= / ⌘0, 默认更小, 一屏看到更多日程
  - Typography (8–16, 默认 10): 行高 = 字号 + 4; GridPlan 不再自动放大行高 (原 12–17pt); View 菜单响应链; UserDefaults fontSize
- 日历筛选改为勾选面板: 可连续勾选多个, ⌥ 点击只看某个日历
  - CalendarFilterController (NSPopover transient + checkbox) 取代 pullDown 菜单

### Fixed

- 月份底色差异过大、已过日期发白看不清
  - 偶数月混色 7% → 2.5%; 区间外 underPageBackground → windowBackground; 已过日程 alpha 0.5 → 0.6
- 标题折行导致每条日程占两行、格子杂乱
  - 移除 char-wrap 换行, 单行截断 + tooltip

## [0.2.0] - 2026-10-06

### Added

- 跨月连续日程视图: 选择年份 + 起止月份 (可跨年), 逐周连续展示, 月份之间不断开
  - WeekLayout: 首月 1 日所在周 → 末月末日所在周; 跨天事件按周分段 + lane 贪心分配; 零点结束不占当日
- 一屏展示全部日程, 不滚动; 横屏 / 竖屏自动分栏重排, 空间富余时标题换行
  - GridPlan: 栏数评分 = 可展示比例⁴ × 行高 × 日宽; water-filling 分配行数; 行高 12–17pt, 0.5pt 量化
- 空间不足的日期显示 +N, 悬停查看未显示日程; 悬停事件查看完整详情
  - DayCellView tooltip 列折叠事件; EventChipView tooltip + AX label = 完整详情
- 按日历筛选显示; 区间与筛选自动记住
  - UserDefaults: range.year / range.startMonth / range.endMonth / hiddenCalendarIDs
- 系统日历变化后自动刷新
  - CalendarStore actor (只读 EKEventStore); EKEventStoreChanged / 时区 / locale 防抖重读; NSCalendarDayChanged 重排; entitlements + NSCalendarsFullAccessUsageDescription
  - debug.sh `open -g` + Debug tag 不 activate: 调试实例不抢前台

## [0.1.0] - 2026-10-06

### Added

- 首个 macOS App: 启动显示 Hello World 窗口
  - Swift 6 + AppKit (无 SwiftUI / nib); main.swift 手动启动 + 代码构建主菜单; 原生 Xcode 工程; macOS 14+
- 支持一条命令构建并安装本机 App, 验证启动后保持打开
  - scripts/install-local.sh: Release 构建 / 签名检查 / 安装 / 启动验证; scripts/debug.sh: 多 worktree 并行 Debug 实例 + 输出 pid
- 可选用开发者证书签名构建, 重新安装后日历授权不丢失
  - install-local.sh / debug.sh 接收 DEVELOPMENT_TEAM → Automatic + Apple Development 签名; 默认 ad-hoc
- 支持按版本标签手动构建并发布 GitHub Release
  - .github/workflows/release.yml: workflow_dispatch (--ref tag) / 校验 tag = MARKETING_VERSION + 在 master / Universal 构建 / zip / gh release
- 正式版与调试版使用独立名称, 共用日历图标; 调试版增加小型 D 标记
  - Debug 独立 PRODUCT_NAME / Bundle ID / AppIconDebug; JJCAL_DEBUG_TAG → 窗口标题显示 worktree 名

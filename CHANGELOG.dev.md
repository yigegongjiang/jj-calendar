```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

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

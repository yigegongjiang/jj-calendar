```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

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

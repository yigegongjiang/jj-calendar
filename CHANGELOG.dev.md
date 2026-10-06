```When Editing
本文档作用: 面向开发者的发版记录; CHANGELOG.md 的超集, 1:1 镜像 + 技术变更子项
遵循 AGENTS.md 文档编写规范
- 每条主项 = CHANGELOG.md 对应条目 (原文), 下方缩进子项承载技术变更
- 子项 MAY 写路径 / 函数 / 机制; ≤ 1 行
```

# Changelog (developer, follow [CHANGELOG.md](./CHANGELOG.md))

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

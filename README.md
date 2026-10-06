```When Editing
本文档作用: 工程总览 (价值主张 / 使用 / 架构 / 结构); MUST NOT 写发布流程 (→ workflow.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 章节按需增删, 只留项目真有的; 首行一行价值主张, MUST NOT 带 LLM 提示
- 短并列项用表格; 可执行步骤 fenced + `#` 注释同行
- NEVER 写「开发」段 (VibeCoding 不向人类解释 dev 命令)
```

# jj-calendar

Swift + AppKit 实现的 macOS 日历查看器: 只读 macOS 系统日历 (Calendar.app) 数据, 按个人习惯定制渲染; 补足系统日历查看日程的不便.

## 核心要求（MUST）

- 只读: 仅读取 + 渲染日历数据; MUST NOT 调用任何写接口 (`EKEventStore.save` / `remove` / `commit` / 新建日历 ...). 写能力未来可能加, 需人类明确提出.
- 定制查看: 以「方便查看日程」为唯一目标; 布局 / 信息密度 / 筛选按个人习惯定制, MUST NOT 复刻系统日历的全部功能.
- 简洁实用高效率: 个人自用; 界面清晰紧凑, 最大化利用屏幕; 实用优先, 美观不作为目标.
- 数据同步: 系统日历数据变化 (`EKEventStoreChanged`) 后尽快刷新界面; MUST NOT 依赖手动刷新.
- 稳定性: 长期运行稳定, 无崩溃 / 资源泄漏 / 随运行时间增长的性能劣化.
- App 性能: 启动 + 交互快速; 数据读取 MUST NOT 阻塞 UI.
- 不要过度设计

## 规划

<!-- prettier-ignore -->
| 阶段 | 内容 |
| --- | --- |
| 当前 | 跨月连续日程视图 (EventKit 只读) |
| 后续 MAY | Reminders (提醒事项) 只读接入 |
| 后续 MAY | 写能力 (人类明确提出后) |

## 使用

安装位置: `/Applications/jj-calendar.app`;

- 顶栏: 年份 + 起始月 + 结束月 (结束月 < 起始月 → 跨入次年, 最多 12 个月) + 日历筛选 (按日历隐藏); 选择持久化
- 网格: 起始月 1 日所在周 → 结束月末日所在周, 逐周连续, 月份间不断行; 月份 = 交替底色 + 阶梯粗线 + 左侧月份标注
- 一屏铺满, 不滚动: 周行自上而下, 一栏放不下按阅读顺序续排到右侧下一栏; 横屏 / 竖屏自动重排
- 全天 / 跨天事件 = 横条 (跨周分段, `◂` = 上周延续); 单日定时事件 = 色点 + 时间 + 标题, 空间富余时标题换行
- 空间不足时日期格右上 `+N` 折叠, 悬停列出未显示日程; 悬停任一事件看完整详情
- 系统日历变更 / 跨天 / 时区变化自动刷新

## 架构

- Swift 6 + AppKit, 仅 macOS; NEVER 使用 SwiftUI
- 纯代码 UI: `main.swift` 手动启动 `NSApplication` + `AppDelegate`; 无 storyboard / xib; 主菜单代码构建
- 原生 `jj-calendar.xcodeproj` + shared scheme `jj-calendar`; `xcodebuild` 编译 / 组装 `.app` / 签名 (默认 ad-hoc, 传 Team 用 Apple Development)
- macOS 14+ (EventKit `requestFullAccessToEvents` 起点); 无第三方依赖
- 数据: `CalendarStore` actor 持有唯一 `EKEventStore`, 查询在 actor 执行器上 → `Sendable` 值类型回主线程; `EKEventStoreChanged` 防抖 300ms 重读
- 排版: `WeekLayout` 生成周行 (横条 lane 贪心分配) → `GridPlan` 按窗口尺寸选栏数 (优先全部展示, 其次行高 × 日宽) + water-filling 分配行数 → 视图只做摆放
- Debug / Release 独立 PRODUCT_NAME + Bundle ID (`com.yigegongjiang.jj-calendar[.debug]`) + 图标 (Debug 带 D 标记)

## 日历权限

- EventKit 无只读授权级别: 读取需 full access (读写合一) → 只读由代码约束保证, 见 [核心要求](#核心要求must)
- Info.plist: `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription`; Reminders 接入时加 `INFOPLIST_KEY_NSRemindersFullAccessUsageDescription`
- Hardened Runtime entitlement: `com.apple.security.personal-information.calendars` (Reminders 对应 `com.apple.security.personal-information.reminders` 待核实)
- 风险: ad-hoc 签名的 TCC 授权绑定 cdhash, 每次重新构建可能丢失授权需重新允许 → 传 DEVELOPMENT_TEAM 用 Apple Development 签名规避; Debug / Release Bundle ID 不同, 各自独立授权

## 结构

<!-- prettier-ignore -->
| 路径 | 作用 |
| --- | --- |
| `Sources/jj-calendar/main.swift` | 入口: 启动 NSApplication |
| `Sources/jj-calendar/AppDelegate.swift` | 窗口 + 主菜单 |
| `Sources/jj-calendar/MainViewController.swift` | 主界面: 顶栏 + 授权 + 数据刷新 + 日历筛选 |
| `Sources/jj-calendar/CalendarStore.swift` | EventKit 只读访问 (actor) |
| `Sources/jj-calendar/WeekLayout.swift` | 连续周网格模型 + 一屏排版 `GridPlan` |
| `Sources/jj-calendar/WeekGridView.swift` | 网格容器 + 星期表头 + 事件文案 |
| `Sources/jj-calendar/WeekRowView.swift` | 周行 / 日期格 / 事件 chip 渲染 |
| `Sources/jj-calendar/jj-calendar.entitlements` | Hardened Runtime 日历权限 |
| `scripts/debug.sh` | Debug 构建 + 重启本 worktree 实例 |
| `scripts/install-local.sh` | Release 构建 + 安装 + 打开 |
| `.github/workflows/release.yml` | 手动触发 (按 tag) 构建 + GitHub Release |
| `version.xcconfig` | 版本号 |

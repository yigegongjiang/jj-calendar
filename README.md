```When Editing
本文档作用: 工程要点 (价值主张 / 核心要求 / 架构约束); MUST NOT 写发布流程 (→ workflow.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 只写重点; MUST NOT 写文件结构 / 功能流水账 / 代码可直接看出的细节
- 首行一行价值主张, MUST NOT 带 LLM 提示
- NEVER 写「开发」段 (VibeCoding 不向人类解释 dev 命令)
```

# jj-calendar

只读 macOS 系统日历, 按个人习惯渲染的日程查看器.

## 核心要求 (MUST)

- 只读: EventKit 只有 full access, 只读由代码保证; MUST NOT 调用任何写接口 (人类明确提出前)
- 只为「方便查看日程」定制; 紧凑, 最大化利用屏幕; MUST NOT 复刻系统日历
- 系统日历变化自动刷新; MUST NOT 依赖手动刷新
- 长期运行稳定: 无崩溃 / 泄漏 / 性能劣化; 数据读取 MUST NOT 阻塞 UI
- 所有行为 MUST 通过 accessibility 透出自动化控制节点, 后台可完整操作; Debug 实例启动 + 操作 MUST NOT 干扰人类
- 不过度设计

## 架构

- Swift 6 + AppKit, macOS 14+, 纯代码 UI; NEVER SwiftUI; 无第三方依赖
- Debug / Release 独立 Bundle ID (`com.yigegongjiang.jj-calendar[.debug]`), 日历授权各自独立

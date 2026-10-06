```When Editing
本文档作用: 面向使用者的发版记录; 只写用户感受得到的变化, MUST NOT 写技术细节 (→ CHANGELOG.dev.md)
遵循 AGENTS.md 文档编写规范
- 写: 新功能 / 行为修复 / 体验 / 安全 / 命令迁移
- MUST NOT 写: 文件路径 / 函数名 / 组件名 / 依赖包名 / 重构细节
- 单条 ≤ 2 行, 单版本 ≤ 5 条; 段落: Added / Changed / Fixed / Removed / Security
- 无用户可感知变化 → 占位: `跟随版本同步发布`
```

# Changelog

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) + [SemVer](https://semver.org/).

## [0.1.0] - 2026-10-06

### Added

- 首个 macOS App: 启动显示 Hello World 窗口
- 支持一条命令构建并安装本机 App, 验证启动后保持打开
- 可选用开发者证书签名构建, 重新安装后日历授权不丢失
- 支持按版本标签手动构建并发布 GitHub Release
- 正式版与调试版使用独立名称, 共用日历图标; 调试版增加小型 D 标记

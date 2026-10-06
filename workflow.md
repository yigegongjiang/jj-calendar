```When Editing
本文档作用: 工程工作流程 (可用工具 / 调试 / 发布); MUST NOT 写工程说明 (→ README.md) / LLM 约束 (→ AGENTS.md)
遵循 AGENTS.md 文档编写规范
- 所有段落均为条件段, 根据工程实际决定保留或删除; 存在即为明确流程, MUST NOT 附加强度标记
- 发布内按顺序编号步骤; 顶部 TL;DR ≤ 5 行; 删除子段后重编号保持连续
- 风险点 / 不可逆操作用 `>` 引用块; 高危操作 MUST 标禁用条件
```

# 可用工具

- `gh`: 已登录
- GitHub Actions: `.github/workflows/release.yml` 手动触发, push tag 不自动执行; 仅人类要求时 `gh workflow run release.yml --ref vX.Y.Z`
- `xcodebuild` / `swiftformat` / `swiftlint`: 已安装

# 调试

```bash
./scripts/debug.sh [DEVELOPMENT_TEAM]                        # 构建 Debug + 重启本 worktree 实例, 输出 pid=<PID>
./scripts/debug.sh quit                                      # 退出本 worktree 实例
```

验证 → 构建 + 启动；按需使用 accessibility 进行 UI/UX 调试、验证功能、核对结果；界面变更截图检查。

- 多 worktree 并行: 各 worktree 实例并存 (同 bundle id, 按产物路径区分); 窗口标题显示 worktree 目录名
- UI/UX 调试按 PID 定位目标实例 (多实例并存时目标确定); MUST NOT 用应用名 / bundle id 定位
- MUST NOT 绕过 `debug.sh` 自行复制 / 改 bundle id 启动
- 删除 worktree 前 → `./scripts/debug.sh quit`

# 发布

行为 / 交付物变更完成后执行; 纯文档调整不触发。交付 = 预部署 + commit + tag + push (无 remote 时跳过 push)。

## TL;DR

1. 验证: `swiftformat --lint` + `swiftlint`
2. 写版本: `version.xcconfig` + `CHANGELOG.md` + `CHANGELOG.dev.md` 同步编辑 (与 tag 一致)
3. 预部署: `./scripts/install-local.sh [DEVELOPMENT_TEAM]`
4. 发布: commit + annotated tag (`-a -m`) + push branch + tag (有 remote 时)

## 1. 验证

```bash
swiftformat --lint Sources
swiftlint --strict
```

## 2. 写版本

- 版本号: 默认递增 PATCH (第三位); 超大功能更新/调整 → MINOR; 禁止 → MAJOR（除非人类主动要求）.
- 根目录 `version.xcconfig`: `MARKETING_VERSION` = X.Y.Z, `CURRENT_PROJECT_VERSION` +1;
- `CHANGELOG.md` + `CHANGELOG.dev.md` 记录每次升级 (tag = `vX.Y.Z`)

## 3. 预部署

信赖并执行 `./scripts/install-local.sh [DEVELOPMENT_TEAM]` 脚本（能力完全交由它封装、提供、执行）

## 4. 发布

```bash
git diff --cached                                   # 确认暂存内容恰好为本次发布变更
git commit -m "chore(release): vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin "$(git branch --show-current)"       # 仅当 `git remote` 非空
git push origin vX.Y.Z                               # 同上
```

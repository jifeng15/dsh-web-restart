# version.md — 版本信息

> 语义化版本（SemVer）：`MAJOR.MINOR.PATCH`。
> 版本号与 git tag、README 徽章、GitHub Release 保持一致。

## 当前版本：v2.0.0

**主题**：热装免重启（Hot install, no restart）

- 🎉 **热装/热卸插件免重启**：内置 `dsh-web-hot` 宿主插件，通过 `include.update`
  在运行中应用 patch 行，PID 不变。
- ✨ 新命令：`dsh-web install <spec>` / `dsh-web remove <pkg>`（热装优先，失败回退安全重启）、
  `dsh-web session`（报告实际 tmux 会话名）。
- 🛡️ 重启日志显式显示目标会话；install.sh 随装 hot-plugin。
- 📦 已知限制：模块代码级更新仍须重启（Node require 缓存），自动回退。

## 版本历史

| 版本 | Tag | 主题 | 核心内容 |
|---|---|---|---|
| **v2.0.0** | `v2.0.0` | 热装免重启 | 热装/热卸、install/remove/session 命令、补装指引、双语 Changelog |
| **v1.0.0** | `v1.0.0` | 安全重启 | tmux 托管 + tmux server 延迟重启、崩溃熔断、端口/会话自动发现、双语 README |

## 发布流程

```bash
# 1. 更新 version.md + README 徽章 + Changelog
# 2. 提交并推送
git add -A && git commit -m "release: vX.Y.Z ..." && git push origin main
# 3. 打 tag 并推送
git tag vX.Y.Z && git push origin vX.Y.Z
# 4. 创建 Release（含说明）
gh release create vX.Y.Z --title "vX.Y.Z — ..." --notes "..."
```

## 版本策略

- **MAJOR**：破坏性变更（如热装机制上线、命令语义变化）。
- **MINOR**：新增能力（如新命令、新自动发现）。
- **PATCH**：修复（如会话名修复、registry 修复、文档修正）。

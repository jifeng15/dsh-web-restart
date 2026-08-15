# handoff.md — 交接与项目状态

> 本文件用于交接：记录项目当前状态、最近变更、待办、已知问题与踩坑，
> 供下一个在此项目工作的 agent / 维护者快速上手。

## 当前状态（2026-08-16）

- **版本**：v2.0.0（热装免重启版），见 version.md
- **仓库**：https://github.com/jifeng15/dsh-web-restart（public，dsh-plugin / dsh-skill / deepseek-harness 三个 topic）
- **Git**：main 分支，工作树干净，本地 = 远程
- **Releases**：v1.0.0（安全重启）、v2.0.0（热装免重启）均已创建
- **本机状态**：dsh web 运行于 tmux 会话 `0`（注意！不是 `dsh-web`），PID 稳定，
  hot-plugin 路由 `/dsh-web-hot/list` 正常返回 `{"ok":true,"value":[]}`

## 最近完成的变更

| commit | 内容 |
|---|---|
| `d9d467b` | README 首次使用说明 + SKILL.md 补装优化（一并装用户插件，一次重启） |
| `2cfafb0` | README 场景 A/B 同步 v2（install/remove 热装 + restart 兜底） |
| `f8203b6` | SKILL.md：agent 首次使用自动补装 hot-plugin |
| `440be45` | 版本 bump v2.0.0 + Changelog + 中文 README 热装同步 |
| `c6b3475` | `session` 命令 + 重启日志显示目标会话 + 修 cmd_status |
| `319f4e7` | 清理误提交的 node_modules + .gitignore |
| `7df4edb` | **热装/热卸（dsh-web-hot）** + bash install/remove + install.sh 集成 |

## 待办 / 可选改进

- [ ] **热装路由鉴权**：目前只监听 loopback 无鉴权。若用户会开局域网/远程访问，
      建议加 token 或信任层（specs.md 已知限制 3）。
- [ ] **`link:` 本地安装一致性**：本机 profile 的 dsh-web-hot 是 `link:` 指向工作区路径
      （`/Users/mr.jf/Documents/DSH/...`），用户场景应指向 `~/.agents/skills/dsh-web-restart/hot-plugin`。
      本机无需改；文档已说明用户路径。
- [ ] **首次补装体验**：SKILL.md 已指导 agent 补装 hot-plugin，但未在真实"全新用户"
      环境端到端验证过（本机是开发时手动装的）。建议模拟验证一次。
- [ ] **推文分享**：用户准备在 X 平台发布（推文已写好，英文 + 中文），发布后可考虑
      在 README 加"相关讨论"链接。

## 已知问题 / 踩坑（重要！）

1. **tmux 会话名是 `0` 不是 `dsh-web`**：开发调试时多次用错会话名导致重启失败。
   **永远先 `dsh-web session` 查实际会话名**，或用脚本（脚本会自动发现）。
2. **pnpm store 不匹配**：profile 曾用 pnpm 10 装、系统是 pnpm 11 → store v10/v11 冲突，
   报 `ERR_PNPM_UNEXPECTED_STORE`。已用 pnpm 11 重装对齐（store 在 `~/Library/pnpm/store/v11`）。
3. **npm 镜像缺失**：本机 `~/.npmrc` 指向 npmmirror，部分插件（dsh-navbar 等）不在镜像上。
   hot-plugin 的 runPnpm 已固定 `--registry=npmjs.org`；手动 pnpm 时也要带。
4. **pnpm remove 不接受 `--registry`**：runPnpm 需区分 add/update（带 registry）和 remove（不带）。
5. **applyToInclude 失败要回滚**：热装时若 include.update 失败，必须回滚 state 和 patch 层，
   否则留下半装状态（曾导致 modsearch 的脏记录）。
6. **`npx skills add` 不装 hot-plugin**：只拷文件。这是 v2 的安装断点，已由
   SKILL.md 的"首次补装"指引解决（agent 自动补装）。
7. **同步执行重启 = 杀 agent 宿主**：restart 必须走 tmux run-shell 延迟执行。

## 安全提醒（写入 AGENTS.md 的铁律）

- 不要手动 `tmux send-keys -t <会话名>` 绕过脚本——用 `dsh-web.sh`。
- `node_modules/` 永不提交。
- 改 README 前先核对 scripts/ 实际命令，不承诺未实现功能。
- 中英文 README 必须同步。

## 下一步建议

1. 若要对"全新用户首次使用"做端到端验证：模拟 `npx skills add` 安装 → 检查
   hot-plugin 缺失 → 确认 agent 补装指引可行。
2. 决定是否加热装路由鉴权。
3. 推文发布后同步 README（可选）。

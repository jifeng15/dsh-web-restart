# AGENTS.md — dsh-web-restart 项目约定

本文件是项目级指令，任何 agent 在本仓库内工作时都应遵循。

## 项目是什么

**dsh-web-restart** 是一个 DeepSeek Harness（DSH）skill + 配套工具，让 dsh web 实现"真·热装载"：

- **热装/热卸插件**（免重启）：内置 `dsh-web-hot` 宿主插件，通过 `include.update` 在运行中应用 patch。
- **安全重启**（兜底）：tmux 托管 + tmux server 独立延迟重启，覆盖改配置、升级本体、迁移。
- **崩溃自动重启** + 3 次熔断（`run-loop.sh`）。

当前版本：**v2.0.0**（见 version.md）。

## 关键文件

| 文件 | 作用 |
|---|---|
| `scripts/dsh-web.sh` | 主命令入口（start/restart/install/remove/upgrade/status/session 等） |
| `hot-plugin/` | 热装宿主插件（index.js 路由 + manager.js 核心逻辑），纯 JS 无构建 |
| `scripts/run-loop.sh` | 崩溃自动重启循环（带熔断） |
| `scripts/install-tmux.sh` | 跨平台 tmux 自动安装 |
| `install.sh` | 一键安装（skill + 命令行 + hot-plugin + tmux） |
| `SKILL.md` | agent 加载的 skill 本体（含操作步骤与边界） |
| `README.md` / `README.zh-CN.md` | 用户文档（英文默认 + 简体中文） |

## 铁律（不可违反）

1. **不要同步执行重启 dsh web**——脚本里 `restart` 必须走 tmux run-shell 延迟执行，
   否则会杀掉承载 agent 的进程、命令当场中断。永远用 `dsh-web.sh`，不要手动
   `tmux send-keys -t <会话名>`（会话名可能不是 `dsh-web`，先 `dsh-web session` 查实际名）。
2. **`npx skills add` 装 skill 不会装 hot-plugin**——若用户要求热装功能，先检查
   profile 是否含 `dsh-web-hot`，缺失则补装（见 SKILL.md 指引）。
3. **`node_modules/` 不提交**（.gitignore 已配）。hot-plugin 依赖由安装时解析，
   仓库保持干净。
4. **不向 README 承诺未实现的功能**——改动文档前先核对 scripts/ 实际命令。

## 常用命令（开发验证）

```bash
bash scripts/dsh-web.sh session     # 查出实际 tmux 会话名
bash scripts/dsh-web.sh status      # 看状态（端口/会话/PID）
bash scripts/dsh-web.sh install <spec>   # 热装插件（免重启）
node --check hot-plugin/*.js        # 语法检查 hot-plugin
bash -n scripts/*.sh                # 语法检查脚本
```

## 边界（已知限制，写文档时保持诚实）

- 模块代码级更新（改插件源码后重装）无法热应用（Node require 缓存），必须重启。
- 升级 dsh 本体必须重启（`dsh-web upgrade` 先升级再重启）。
- 崩溃自动重启是独立可选（run-loop），不是默认。
- 重启电脑后需手动重新 `dsh-web start`（或任何方式打开 dsh web）。

## 版本与发布

- 版本号在 `version.md` 与 README 徽章中维护。
- 发布新版本：`git tag vX.Y.Z && git push origin vX.Y.Z && gh release create vX.Y.Z`。
- 中英文 README 必须同步（README.md 英文默认，README.zh-CN.md 中文）。

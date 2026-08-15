# specs.md — dsh-web-restart 技术规格

## 1. 概述

一个 DeepSeek Harness（DSH）skill + 工具集，解决 dsh web 的"热装载"问题：
插件装/卸走**免重启热装**，改配置/升级本体/迁移走**安全重启**，崩溃自动恢复。

## 2. 架构

```
┌──────────────────────────── 用户/agent ────────────────────────────┐
│  dsh-web.sh（bash 主命令）                                         │
│    install/remove → 先试 HTTP 热装，失败回退安全重启                │
│    restart/reload/upgrade → tmux run-shell 延迟重启                │
│    start/stop/status/session/autostart-* → 托管管理                 │
└──────────────┬──────────────────────────────┬─────────────────────┘
               │ HTTP POST /dsh-web-hot/*      │ tmux send-keys（由 tmux server 执行）
               ▼                              ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│ dsh-web-hot（宿主插件，进程内）│   │ tmux server（独立守护进程）      │
│  index.js: HTTP 路由          │   │  run-shell 延迟重启            │
│  manager.js: 热装核心          │   │  崩溃自动重启 run-loop         │
└──────────────┬───────────────┘   └──────────────────────────────┘
               │ include.update（cordis loader API）
               ▼
        dsh web 运行中的 bundle 树
```

## 3. 组件规格

### 3.1 `scripts/dsh-web.sh`（主命令）

| 命令 | 行为 | 实现要点 |
|---|---|---|
| `start` | 启动/接管 | 无会话则创建，未托管则自动迁入 tmux；`resolve_session` 自动发现会话名 |
| `restart` | 安全重启 | `tmux run-shell -b` 延迟执行 C-c + 重拉；日志显式显示目标会话 |
| `reload` | 改配置后重启 | = restart（配置在启动时合成） |
| `upgrade` | 升级本体 | 检测 npm/pnpm 安装方式 → 升级 → restart |
| `install <spec>` | 装插件 | 先试 HTTP 热装（免重启）；失败回退 `pnpm add` + restart |
| `remove <pkg>` | 卸插件 | 先试 HTTP 热卸；失败回退 `pnpm remove` + restart |
| `stop` / `status` / `attach` | 管理 | 会话发现 + 端口发现 |
| `session` | 报告实际会话名 | `resolve_session` 结果（不假设 dsh-web） |
| `autostart-on/off/status` | 开机自启 | launchd（macOS）/ systemd（Linux），默认关闭 |
| `report-port` | 端口报告 | 写 `~/.dsh/logs/last-port.txt`；非默认端口才通知 |

**自动发现（关键机制）**：
- `discover_port`：显式配置 > 进程命令行 `--port` > 进程监听端口 > node 扫描 > 默认 3080。
  处理 `--port 0`（随机端口）——命令行解析到 0 时跳过，走进程监听扫描。
- `resolve_session`：默认 `dsh-web`，找不到时按「端口有监听 + pane 前台是 node」发现
  任意托管会话（pid 树关联优先，启发式兜底）。

### 3.2 `hot-plugin/`（热装宿主插件，纯 JS）

- `package.json`：声明 `dsh.bundle.patch`，peer 依赖 cordis / cordis-plugin-include / dsh-app-boot。
- `index.js`：cordis 插件入口（`export function apply(ctx)`），注册 `webServer` 前缀路由
  `/dsh-web-hot/*`（install / uninstall / update / setEnabled / list）。
- `manager.js`：热装核心：
  - `installBundle`：`pnpm add`（带 `--config.minimumReleaseAge=0` 绕过 pnpm 11 发布年龄门槛、
    `--registry=npmjs.org` 绕过镜像缺失）→ 读 bundle 的 `cordis.patch.yml` → 写用户补丁层
    `cordis.patch.yml` → `applyToInclude`（`ctx.loader.entries()` 找 `id: 'include'` →
    `include.update({ config: { patches } })`）→ 热应用。
  - applyToInclude 失败时**回滚** state 与 patch 层（不留下半装状态）。
  - `uninstallBundle` / `updateBundle` / `setEnabled` 同理，均走 include.update。
  - state 文件：`dsh-web-hot.state.json`（记录管理的 bundle 与 rowIds）。
  - pnpm 运行器：`runPnpm` 区分 `add/update`（带 registry）与 `remove`（不带，remove 不接受该参数）。

### 3.3 `scripts/run-loop.sh`（崩溃自动重启）

- 循环执行 `dsh web`；退出码 130/143（信号）→ 主动停止不重启。
- 非信号退出 → 崩溃计数 +1；连续 3 次熔断（`--max-crashes`，默认 3）→ 停止并留计数文件。
- 稳定运行超过 `--stable-seconds`（默认 60s）→ 计数清零（健康判定）。
- 开关：`DSH_CRASH_RESTART=0` 关闭。

### 3.4 `install.sh`（一键安装）

1. 复制 skill 文件到 `~/.agents/skills/dsh-web-restart/`（含 hot-plugin/）。
2. 装命令行到 `~/bin/dsh-web`。
3. 检测并自动安装 tmux（缺失时）。
4. `install_hot_plugin`：`dsh plugin --profile web add "link:<skill_dir>/hot-plugin"`。
   - 依赖 dsh CLI + pnpm；缺失时跳过（热装降级为安全重启，功能不阻塞）。

## 4. 数据流

### 热装（install，免重启）

```
dsh-web.sh install dsh-foo
  → curl POST /dsh-web-hot/install {spec: "dsh-foo"}
    → manager.installBundle
      → pnpm add dsh-foo（profile 目录，官方 registry）
      → 读 dsh-foo 的 dsh.bundle.patch → patch rows
      → 写 cordis.patch.yml（用户补丁层，持久化）
      → applyToInclude（include.update）→ 热应用
      → 写 dsh-web-hot.state.json
  → {"ok": true}（PID 不变）
```

### 安全重启（restart）

```
dsh-web.sh restart
  → resolve_session（发现实际会话，如 "0"）
  → tmux run-shell -b "sleep 3; send-keys C-c; sleep 2; send-keys 'dsh web' Enter"
  → tmux server 独立执行（即使 agent 被杀也完成）
  → 5-8 秒后 dsh web 重启，用户刷新
```

## 5. 环境依赖

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| tmux | 托管 + 独立重启 | 自动安装（install-tmux.sh） |
| pnpm | 插件安装（dsh-web-hot 调用） | 热装降级为安全重启 |
| dsh CLI | install.sh 装 hot-plugin | 跳过 hot-plugin |
| node | hot-plugin 运行（dsh web 自带） | — |
| curl / lsof / ps / pgrep | 脚本探测 | — |

## 6. 已知限制

1. **模块代码级更新必须重启**：Node require 缓存无法热清除，改插件源码后重装需重启。
2. **升级 dsh 本体必须重启**：hot-plugin 只是插件，管不了宿主升级。
3. **热装路由无鉴权**：监听 loopback（默认 127.0.0.1），局域网/远程暴露时需自行加信任层。
4. **`link:` 本地安装**：`npx skills add` 装的 skill，hot-plugin 需 agent 首次补装
   （SKILL.md 有指引）。
5. **崩溃自动重启非默认**：需 `DSH_CRASH_RESTART=1`（或脚本默认开启但可关）。

## 7. 测试要点

- `bash -n scripts/*.sh` 语法检查；`node --check hot-plugin/*.js`。
- 热装验证：`curl POST /dsh-web-hot/install` → 检查 `{"ok":true}` + PID 不变。
- 会话发现：`dsh-web session` 应输出实际会话名（如 `0`），不是假设的 `dsh-web`。
- 端口发现：用 `--port 0` 启动 → `status` 应解析出随机端口。

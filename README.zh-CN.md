# dsh-web-restart

> **让 dsh web 实现"真·热装载"**：装插件、改配置、升级本体后，不用再手动跑去命令行重启，实时看到效果。

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-yes-2ea44f?logo=deepseek)](https://github.com/topics/dsh-plugin)
[![dsh-skill](https://img.shields.io/badge/dsh--skill-yes-8e44ad?logo=deepseek)](https://github.com/topics/dsh-skill)
[![deepseek-harness](https://img.shields.io/badge/deepseek--harness-yes-4d6bfe)](https://github.com/topics/deepseek-harness)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-2.0.0-4d6bfe)

**简体中文** | [English](README.md)

## 更新记录

### v2.0.0（热装免重启）

- 🎉 **新增免重启热装/热卸**：装/卸插件不再需要重启——内置 `dsh-web-hot` 宿主插件，
  通过 `include.update` 在运行中热应用 patch 行，**PID 全程不变**。
- ✨ 新命令：`dsh-web install <spec>`（热装优先，失败回退安全重启）、
  `dsh-web remove <pkg>`（热卸优先，失败回退安全重启）。
- 🛡️ `dsh-web session`：随时查出实际 tmux 会话名（自动发现，不假设 `dsh-web`）。
- 📦 模块代码级更新仍须重启（Node require 缓存）——结构性限制，自动回退。

### v1.0.0（安全重启）

- 首版：tmux 托管 + tmux server 独立延迟重启，覆盖装插件/改配置/升级本体。
- 崩溃自动重启 + 3 次熔断；端口/会话自动发现；双语 README。

## 它解决什么难题（我们实际遇到的）

我在使用 **dsh web** 的过程中发现：DSH 有三类变更**必须重启进程才能生效**——装/卸/更新插件（bundle 层启动时合成）、修改 profile 配置（`cordis.patch.yml`）、升级 dsh 本体。

但每次遇到这些情况，我都得**离开对话窗口、跑去命令行重新输入 `dsh web`**，然后刷新页面才能看到效果。整个过程：

- ❌ **不及时**：装完插件不能立刻看到效果，体验断裂
- ❌ **要手动**：明明在对话里让 agent 装了插件，还得自己开终端敲命令
- ❌ **容易断**：直接杀进程重启还会连累正在运行的 agent 会话（"做了很多轮都没完成"）

**这个 skill 把"热重载"和"热重启"同步起来**——让 DSH 该热重载的继续热重载（skill、AGENTS.md、settings 本来就是），该重启的**由 agent 自动安全地重启**，让 dsh web 实现**真正的热装载**：你只管在对话里装插件，刷新一下就能实时看到效果，**不用再手动去重启**。

## 快速开始

三种安装方式，任选其一：

**① 对话安装（推荐）**——在 DSH 对话里说（**记得附上仓库地址**，agent 才能知道去哪安装）：

> "**帮我安装 https://github.com/jifeng15/dsh-web-restart**"

agent 会自动完成安装并加载本 skill（skill 是热加载的，装完即用，无需重启）。

**② 一行命令安装**——在自己的终端执行：

```bash
npx -y skills add https://github.com/jifeng15/dsh-web-restart -g -y -a universal --copy
```

**③ clone 手动安装**——想先看源码/自己维护时：

```bash
git clone https://github.com/jifeng15/dsh-web-restart.git && cd dsh-web-restart
bash install.sh
```

装完即可用（见下方"两种使用场景"）。

## 两种使用场景（都支持）

### 场景 A：通过对话使用（推荐）— 你什么都不用敲

你只需要**安装了本 skill 后**，在对话里说"**帮我装 XX 插件**"（XX = 任意**其他**
插件，如 dsh-market）、"**帮我升级 dsh**"，agent 会：

1. 自动加载本 skill
2. 执行插件安装 / 升级
3. 装插件走 **`dsh-web install`（热装免重启）**；升级本体走 `dsh-web upgrade`（先升级再安全重启）
4. 你只需要**刷新一下页面**（装插件甚至可能不用刷新——热装是运行中生效），新插件/新版本立即生效

> 适用：日常通过 DSH 对话操作插件的用户。这是 skill 的**主要使用场景**——它本来就设计给 agent 用的。
>
> **首次使用说明**：第一次热装插件时，agent 会自动安装热装组件并重启一次
> （让组件生效）——你只需刷新那一次。之后每次装插件都是**免重启**的。

### 场景 B：手动命令行使用 — 自己控制

如果你习惯自己开终端操作，装/卸插件用热装命令（免重启），其他场景用统一重启：

```bash
dsh-web install <spec>   # 装插件：热装优先（免重启），失败回退安全重启
dsh-web remove <pkg>     # 卸插件：热卸优先（免重启），失败回退安全重启
dsh-web restart          # 改 profile 配置、升级本体等场景，统一安全重启
dsh-web session          # 随时查看实际 tmux 会话名（自动发现）
dsh-web status           # 随时查看状态
```

> **热装优先，重启兜底**：装/卸插件默认走内置 dsh-web-hot 热装——运行中应用 patch，
> **不用重启、PID 不变**；热装不可用（插件未加载 / 模块代码级更新 / 无法热应用）时
> 自动回退安全重启。
>
> **为什么"多一步"省不掉**：skill 的"自动重启"触发器是 **agent**——你通过对话装插件时
> agent 在场，能自动调起；但你自己开终端装插件时没有 agent 参与，所以必须手动跑一次。
> **这"多一步"是一次性的**：它会把 dsh web 迁入 tmux 托管，之后任何变更（对话方式）
> 就全自动了，不用再管。
>
> 适用：命令行用户、脚本自动化、以及 agent 内部调用。所有命令都**自动**处理 tmux
> 托管、端口发现、会话发现，不需要你先做任何准备。

## 一眼看懂：它能做什么 / 不能做什么

| ✅ **能** | ❌ **不能** |
|---|---|
| **热装/热卸插件**（内置 dsh-web-hot）——**免重启**（不可用时自动回退安全重启） | agent 重启后**无缝继续对话**——重启会短暂断开，需你刷新页面（结构性限制） |
| 装完插件后**自动重启** dsh web，你**不用手动敲任何命令**（对话方式） | **模块代码级更新**无法热应用（Node require 缓存，必须重启） |
| 改完 profile 配置（cordis.patch.yml）后 `reload` 生效 | 让 dsh web **不重启进程**就加载插件/配置（bundle 树启动时合成，必须重启进程；刷新页面只是重启后重连，不是加载手段） |
| `upgrade` 升级 dsh 本体并自动重启 | 重启电脑后自动恢复（需要你重新 `dsh-web start` 一次） |
| 没装 tmux？**自动帮你装**（macOS/Linux 主流包管理器） | 非 npm/pnpm 安装的 dsh 本体无法自动升级（只提示） |
| dsh web 跑在普通终端？**自动迁入 tmux** 托管 | skill 增改、AGENTS.md 修改等（这些**本来就是热加载的**，不需要它） |
| 会话名不叫 `dsh-web`？**自动找到**实际托管会话 | 崩溃自动重启是独立可选功能（run-loop） |
| 端口不是 3080？**自动发现**（含 `--port 0` 随机端口） | — |
| 终端窗口全关，dsh web **照常运行**、随时可重启 | — |

**一句话**：装/卸插件**免重启**（热装），真正必须重启的（改配置、升级本体、迁移）**安全自动重启**并让 dsh web 常驻；你只需要在页面断开后刷新一下。

## 命令

```bash
dsh-web install <spec>   # ★ 装插件：热装优先（免重启），失败回退安全重启
dsh-web remove <pkg>     # ★ 卸插件：热卸优先（免重启），失败回退安全重启
dsh-web restart    # ★ 兜底/其他：装插件后、改配置、升级本体等场景统一安全重启
dsh-web start      # 启动/自动接管（无会话则创建，未托管则迁入 tmux）
dsh-web stop       # 停止
dsh-web status     # 查看会话/端口/PID/日志
dsh-web session    # 查看实际 tmux 会话名（自动发现，不假设 dsh-web）
dsh-web attach     # 进入 tmux 排查
dsh-web autostart-on    # 启用开机自启（默认关闭，用户主动选择；launchd/systemd）
dsh-web autostart-off   # 关闭开机自启
dsh-web autostart-status # 查看自启状态
```

> **热装优先，重启兜底**：`dsh-web install/remove` 先走内置 dsh-web-hot 热装——
> **免重启**；热装不可用（插件未加载 / 变更无法热应用）时自动回退安全重启。
> `dsh-web restart` 仍是其他场景（改配置、升级本体、迁移）的统一命令。

> **开机自启是可选功能，默认关闭**——skill 不会自动启用任何自启项。需要开机后 dsh web 自动在 tmux 里起来时，用户主动执行 `dsh-web autostart-on` 即可。

> **端口通知策略**：`start`/`restart` 后实际端口写入 `~/.dsh/logs/last-port.txt`。
> 端口为**默认值（3080）时不发通知**（大家都知道）；**非默认端口**（被占用/随机）
> 才发系统通知告知实际端口——尤其自启是无人值守场景，用户需要知道连哪里。

## 约定与边界

| 项 | 默认值 | 覆盖 |
|---|---|---|
| tmux 会话名 | `dsh-web`（找不到时自动发现） | `DSH_WEB_SESSION` |
| 端口 | **自动发现**（显式配置 > 进程命令行 `--port` > 进程监听端口 > node 扫描 > 默认 3080） | `DSH_WEB_PORT` |
| 启动命令 | `dsh web` | `DSH_CMD` |

- **端口自动发现**：用户用 `--port 8080` 或 `--port 0`（随机端口）启动 dsh web 也能正确工作——脚本会从进程命令行或实际监听端口自动解析，无需手动指定。
- 终端全关不影响：tmux server 是守护进程，detach 后继续运行。
- 重启电脑 / `tmux kill-server` 后：**用你习惯的方式重新打开 dsh web 即可**——
  `dsh-web start` 最省事（一步建 tmux + 启动 + 托管）；直接 `dsh web` 也可以，
  第一次 `restart` 会自动迁入 tmux（多一次自动迁移，之后全自动）。
- 无法自动安装 tmux 时会打印各平台手动命令。

## 原理（30 秒版）

```bash
tmux run-shell -b "sleep 3; tmux send-keys -t dsh-web C-c; sleep 2; tmux send-keys -t dsh-web 'dsh web' Enter"
```

tmux server 是独立守护进程，不依赖 dsh web 存活——即使调用方（agent）随 dsh web 被杀，重启依然完成。

## 架构与数据流（技术细节）

### 组件

| 组件 | 职责 |
|---|---|
| `scripts/dsh-web.sh` | 主命令行（start/restart/install/remove/upgrade/status/session/autostart-*） |
| `hot-plugin/`（dsh-web-hot） | 宿主插件：`include.update` 热装/热卸（免重启） |
| `scripts/run-loop.sh` | 崩溃自动重启循环（3 次熔断） |
| `scripts/install-tmux.sh` | 跨平台 tmux 自动安装 |
| `install.sh` | 一键安装（skill + 命令行 + hot-plugin + tmux） |

### 热装（免重启）数据流

```
dsh-web.sh install <spec>
  → POST /dsh-web-hot/install {spec}
    → pnpm add <spec>（profile 目录，官方 registry）
    → 读 bundle 的 dsh.bundle.patch → patch 行
    → 写 cordis.patch.yml（用户补丁层，持久化）
    → include.update（热应用，PID 不变）
    → 记录 dsh-web-hot.state.json
  → {"ok": true}
```

### 安全重启数据流

```
dsh-web.sh restart
  → resolve_session（发现实际会话，如 "0"）
  → tmux run-shell -b "sleep 3; C-c; sleep 2; 'dsh web'"
  → tmux server 独立执行（即使 agent 被杀也完成）
  → 5-8 秒后 dsh web 重启；用户刷新
```

### 环境依赖

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| tmux | 托管 + 独立重启 | 自动安装 |
| pnpm | 插件安装（经 dsh-web-hot） | 热装降级为安全重启 |
| dsh CLI | install.sh 装 hot-plugin | 跳过 hot-plugin |
| curl/lsof/ps/pgrep | 探测 | — |

## 踩过的坑

1. 同步重启 = 杀宿主进程 = 命令中断 → 用 `tmux run-shell -b`
2. `nohup ... &` 排定后台任务会被调用方回合清理 → 用 tmux server
3. GitHub tarball URL 装插件会让 pnpm 锁文件缺 integrity → 用 `github:owner/repo#ref`

## License

MIT

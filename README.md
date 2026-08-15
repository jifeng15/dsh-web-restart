# dsh-web-restart

> **让 dsh web 实现"真·热装载"**：装插件、改配置、升级本体后，不用再手动跑去命令行重启，实时看到效果。

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-yes-2ea44f?logo=deepseek)](https://github.com/topics/dsh-plugin)
[![Awesome DSH Plugin](https://awesome-dsh-plugin.com/badge.svg)](https://awesome-dsh-plugin.com)
![License](https://img.shields.io/badge/license-MIT-blue)

## 它解决什么难题（我们实际遇到的）

我在使用 **dsh web** 的过程中发现：DSH 有三类变更**必须重启进程才能生效**——装/卸/更新插件（bundle 层启动时合成）、修改 profile 配置（`cordis.patch.yml`）、升级 dsh 本体。

但每次遇到这些情况，我都得**离开对话窗口、跑去命令行重新输入 `dsh web`**，然后刷新页面才能看到效果。整个过程：

- ❌ **不及时**：装完插件不能立刻看到效果，体验断裂
- ❌ **要手动**：明明在对话里让 agent 装了插件，还得自己开终端敲命令
- ❌ **容易断**：直接杀进程重启还会连累正在运行的 agent 会话（"做了很多轮都没完成"）

**这个 skill 把"热重载"和"热重启"同步起来**——让 DSH 该热重载的继续热重载（skill、AGENTS.md、settings 本来就是），该重启的**由 agent 自动安全地重启**，让 dsh web 实现**真正的热装载**：你只管在对话里装插件，刷新一下就能实时看到效果，**不用再手动去重启**。

## 两种使用方式（都支持）

### 方式 A：通过对话使用（推荐）— 你什么都不用敲

你只需要在对话里说"**帮我装 XX 插件**"、"**帮我升级 dsh**"，agent 会：

1. 自动加载本 skill
2. 执行插件安装 / 升级
3. **自动调用** `dsh-web restart` / `dsh-web upgrade`（agent 内部直接调脚本，你全程不碰命令行）
4. 你只需要**刷新一下页面**，新插件/新版本立即生效

> 适用：日常通过 DSH 对话操作插件的用户。这是 skill 的**主要消费方式**——它本来就设计给 agent 用的。

### 方式 B：手动命令行使用 — 自己控制

如果你习惯自己开终端操作（比如直接 `dsh plugin add`，不经过对话），那在这些操作**之后**手动执行一次：

```bash
dsh-web restart    # 装/卸/更新插件后
dsh-web reload     # 改完 profile 配置（cordis.patch.yml）后
dsh-web upgrade    # 升级 dsh 本体后
dsh-web status     # 随时查看状态
```

> 适用：命令行用户、脚本自动化、以及 agent 内部调用。所有命令都**自动**处理 tmux 托管、端口发现、会话发现，不需要你先做任何准备。

## 一眼看懂：它能做什么 / 不能做什么

| ✅ **能** | ❌ **不能** |
|---|---|
| 装完插件后**自动重启** dsh web，你**不用手动敲任何命令**（对话方式） | agent 重启后**无缝继续对话**——重启会短暂断开，需你刷新页面（结构性限制） |
| 改完 profile 配置（cordis.patch.yml）后 `reload` 生效 | 让 dsh web 在**不重启**的情况下加载插件/配置（bundle 树启动时合成，必须重启） |
| `upgrade` 升级 dsh 本体并自动重启 | 重启电脑后自动恢复（需要你重新 `dsh-web start` 一次） |
| 没装 tmux？**自动帮你装**（macOS/Linux 主流包管理器） | 在 dsh web **崩溃**时自动拉起（只处理正常重启） |
| dsh web 跑在普通终端？**自动迁入 tmux** 托管 | skill 增改、AGENTS.md 修改等（这些**本来就是热加载的**，不需要它） |
| 会话名不叫 `dsh-web`？**自动找到**实际托管会话 | 非 npm/pnpm 安装的 dsh 本体无法自动升级（只提示） |
| 端口不是 3080？**自动发现**（含 `--port 0` 随机端口） | — |
| 终端窗口全关，dsh web **照常运行**、随时可重启 | — |

**一句话**：DSH 需要重启才能生效的变更（**装插件、改 profile 配置、升级本体**），它负责安全自动重启并让 dsh web 常驻；你只需要在页面断开后刷新一下。

## 快速开始

```bash
# 方式一：一行安装（推荐）
npx -y skills add https://github.com/jifeng15/dsh-web-restart -g -y -a universal --copy

# 方式二：clone 手动安装
git clone https://github.com/jifeng15/dsh-web-restart.git && cd dsh-web-restart
bash install.sh
```

装完即可用（见上方"两种使用方式"）。

## 命令

```bash
dsh-web start      # 启动/自动接管（无会话则创建，未托管则迁入 tmux）
dsh-web restart    # 安全自动重启（装插件后）
dsh-web reload     # 改完 profile 配置后重启生效
dsh-web upgrade    # 升级 dsh 本体并自动重启
dsh-web stop       # 停止
dsh-web status     # 查看会话/端口/PID/日志
dsh-web attach     # 进入 tmux 排查
dsh-web autostart-on    # 启用开机自启（默认关闭，用户主动选择；launchd/systemd）
dsh-web autostart-off   # 关闭开机自启
dsh-web autostart-status # 查看自启状态
```

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

## 踩过的坑

1. 同步重启 = 杀宿主进程 = 命令中断 → 用 `tmux run-shell -b`
2. `nohup ... &` 排定后台任务会被调用方回合清理 → 用 tmux server
3. GitHub tarball URL 装插件会让 pnpm 锁文件缺 integrity → 用 `github:owner/repo#ref`

## License

MIT

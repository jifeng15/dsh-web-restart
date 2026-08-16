# dsh-web-restart

> **让 dsh web 实现"真·热装载"**：装插件、改配置、升级本体后，不用再手动跑去命令行重启，实时看到效果。

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-yes-2ea44f?logo=deepseek)](https://github.com/topics/dsh-plugin)
[![dsh-skill](https://img.shields.io/badge/dsh--skill-yes-8e44ad?logo=deepseek)](https://github.com/topics/dsh-skill)
[![deepseek-harness](https://img.shields.io/badge/deepseek--harness-yes-4d6bfe)](https://github.com/topics/deepseek-harness)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-2.0.9-4d6bfe)

**简体中文** | [English](README.en.md)

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

> `npx skills add` 只装 **skill 文件**（agent 用 skill 内的脚本路径，不需要命令）。
> 想要终端里能用 **`dsh-web` 命令**，再执行一次：
> `bash ~/.agents/skills/dsh-web-restart/install.sh --bin-only`
> （装到 `~/bin/dsh-web` 并自动把 `~/bin` 加进 shell PATH）。

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
dsh-web remove <pkg>     # 卸插件：热卸优先（免重启），失败回退安全重启（拒绝 CLI 管理的插件——请用 `dsh plugin --profile web remove`）
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
| dsh web 跑在普通终端？**自动迁入 tmux** 托管（运行中执行一次 `dsh-web start`/`restart`；或启用看门狗后完全自动） | skill 增改、AGENTS.md 修改等（这些**本来就是热加载的**，不需要它） |
| 会话名不叫 `dsh-web`？**自动找到**实际托管会话 | 崩溃自动重启是独立可选功能（run-loop） |
| 端口不是 3080？**自动发现**（含 `--port 0` 随机端口） | — |
| 终端窗口全关，dsh web **照常运行**、随时可重启 | — |

**一句话**：装/卸插件**免重启**（热装），真正必须重启的（改配置、升级本体、迁移）**安全自动重启**并让 dsh web 常驻；你只需要在页面断开后刷新一下。

## 命令

```bash
dsh-web install <spec>   # ★ 装插件：热装优先（免重启），失败回退安全重启
dsh-web remove <pkg>     # ★ 卸插件：热卸优先（免重启），失败回退安全重启（拒绝 CLI 管理的插件——请用 `dsh plugin --profile web remove`）
dsh-web restart    # ★ 兜底/其他：装插件后、改配置、升级本体等场景统一安全重启
dsh-web reload     # 改完 profile 配置（cordis.patch.yml）后重启生效（= restart）
dsh-web upgrade    # 升级 dsh 本体并自动重启
dsh-web start      # 启动/自动接管（无会话则创建，未托管则迁入 tmux）
dsh-web stop       # 停止（Ctrl-C；tmux 托管保留，`restart` 可快速恢复）
dsh-web quit       # 彻底退出：停止 + 关闭托管会话 + 清理痕迹（不再挂后台）
dsh-web status     # 查看会话/端口/PID/日志
dsh-web session    # 查看实际 tmux 会话名（自动发现，不假设 dsh-web）
dsh-web attach     # 进入 tmux 排查
dsh-web autostart-on    # 启用开机自启（默认关闭，用户主动选择；launchd/systemd）
dsh-web autostart-off   # 关闭开机自启
dsh-web autostart-status # 查看自启状态
dsh-web watchdog-on     # 启用 launchd 看门狗：每 30s 把未托管的 dsh web 自动迁入 tmux（默认关闭）
dsh-web watchdog-off    # 关闭看门狗
dsh-web watchdog-status # 查看看门狗状态
dsh-web repair       # 修复配置：同文件重复 id / ghost bundle / 跨来源重复（改前自动备份）
dsh-web health-check # 检查端口 + 配置树——是进程问题还是配置问题？
dsh-web preflight    # boot 前自检（start/restart 自动执行）：清跨来源重复
# 内部命令：report-port（写实际端口到 last-port.txt + 非默认端口通知）、watchdog-tick（launchd 调用）
```

> **热装优先，重启兜底**：`dsh-web install/remove` 先走内置 dsh-web-hot 热装——
> **免重启**；热装不可用（插件未加载 / 变更无法热应用）时自动回退安全重启。
> `dsh-web restart` 仍是其他场景（改配置、升级本体、迁移）的统一命令。
>
> **每个插件只有一个主人（单源原则）**：插件只从一个来源挂载——要么
> `dsh plugin --profile web add|remove`（`dsh.profile.bundles` 列表），要么热装
> （`cordis.patch.yml` patch 层），**不能两边都有**。若同一插件出现在两边（如外部
> `dsh plugin add` 收编了之前热装的插件），`preflight`（`start`/`restart` 自动
> 执行）与 `repair` 会自动检测并移除 patch 层重复行——下次启动不会再因
> `duplicate loader entry id` 崩溃。卸载侧同样：`dsh-web remove` 拒绝 CLI 管理的
> 插件（会留 ghost bundle），引导走 `dsh plugin remove`。

> **开机自启是可选功能，默认关闭**——skill 不会自动启用任何自启项。需要开机后 dsh web 自动在 tmux 里起来时，用户主动执行 `dsh-web autostart-on` 即可。

> **端口通知策略**：`start`/`restart` 后实际端口写入 `~/.dsh/logs/last-port.txt`。
> 端口为**默认值（3080）时不发通知**（大家都知道）；**非默认端口**（被占用/随机）
> 才发系统通知告知实际端口——尤其自启是无人值守场景，用户需要知道连哪里。

### 看门狗：真·自动接管（可选，默认关闭）

`dsh-web watchdog-on` 安装 launchd LaunchAgent，每 30s 检测一次：如果 dsh web
正在监听但**不在 tmux 托管**（如你在普通终端里起的），就自动把它迁入 tmux——
之后**不管你怎么启动的，关终端都不会杀掉 dsh web**。看门狗只迁移**运行中**的
web，绝不主动启动停止的 web。`dsh-web watchdog-off` 关闭。当前仅 macOS
（Linux systemd timer 后续支持）。

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

### 单源原则（插件为什么不能双挂载）

`dsh plugin --profile web add`（bundle 列表）与热装（用户 patch 层）都往
**同一个 loader** 里注入 include 条目，而 entry id 必须全局唯一——同一插件出现在
两个来源，下次启动就报 `duplicate loader entry id`。本项目强制**每个插件只有一个
主人**：

- 热装拒绝已在 `dsh.profile.bundles` 中的插件（安装时点守卫）；
- `preflight`（`start`/`restart` 自动执行）与 `repair` 检测跨来源重复——
  bundles 声明的 entry id ∩ patch 层行 → 移除 patch 层重复行（bundle 侧为权威）
  并同步 `dsh-web-hot.state.json`；
- `dsh-web-hot` 插件启动自愈——覆盖运行期漂移（HMR 重载、手改 state），经
  `include.update` 热卸载让位。

所以外部 `dsh plugin add` 收编了之前热装的插件时，下次启动前会自动对齐——
不再需要手动清理。

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
4. **已托管时手动再敲 `dsh web`（双启动）** → 新实例抢端口失败（EADDRINUSE），
   旧实例可能被挂起（run-loop 收到信号退出）。别双启动：用 `dsh-web start`/
   `restart`/`status`。误敲了也别慌：看门狗 30s 内自动恢复被暂停的实例，
   `dsh-web restart` 一键恢复规范托管。

## 已知问题 / 可选处理

- **pnpm 11 的 24 小时 minimumReleaseAge 供应链闸门**：锁文件里出现**当天刚发布**
  的插件时，`dsh plugin` / dsh-market 等工具的更新可能警告或失败（"too-young
  release"）。本项目的热装按次用 `--config.minimumReleaseAge=0` 绕过，不受影响；
  dsh-market 会自带一次重试，但可能仍受镜像同步滞后影响（本机 `~/.npmrc` 指向
  npmmirror，dsh-market 未固定官方 registry）。
  **想彻底放行**（例如你经常装当天新发布的插件），可在
  `~/.dsh/profiles/web/pnpm-workspace.yaml` 加：

  ```yaml
  minimumReleaseAge: 0
  ```

  代价：放弃 24h 供应链闸门（防"刚发布即被滥用"的包）。按需取舍，改完
  `dsh-web reload` 生效。

## License

MIT

## 更新记录

### v2.0.9（双启动自愈）

- 💊 看门狗现在**自动恢复被暂停的 dsh web 进程**（SIGCONT，每轮 tick）。如果你在
  已托管时误敲 `dsh web`，新实例抢端口失败（EADDRINUSE）、旧实例可能被挂起——
  看门狗 30s 内把它恢复。恢复指引：`dsh-web restart` 重建规范托管。

### v2.0.8（quit 彻底退出）

- 🚪 **`dsh-web quit`**：彻底退出——停止 dsh web（C-c，兜底 TERM）＋**关闭 tmux
  托管会话**＋清理痕迹（crash-count），系统里不再挂任何 dsh web 相关进程/会话。
  `stop` 只发 Ctrl-C（托管保留，`restart` 快速恢复）；`quit` 是"不干了"的出口。
  看门狗在运行时会提示（它只迁移运行中的 web，不会自动重启已停止的）。

### v2.0.7（与 dsh-market 共存兼容）

- 🔀 `ensureWorkspaceAllowed` 现在**合并**进 dsh-market 写的 `allowBuilds`
  **对象风格**（name→boolean，含它的 "set this to true or false" 模板），不再用
  我们的旧列表格式覆盖它。两个工具写同一个文件不再互相清掉。

### v2.0.6（install.sh 自动补 PATH）

- 🔧 `install.sh` 安装 `dsh-web` 命令并**自动把 bin 目录加进 shell PATH**
  （此前命令装了却找不到）。

### v2.0.5（launchd 看门狗 · 真·自动接管）

- 🐕 **`dsh-web watchdog-on`**：启用 launchd 看门狗（默认关闭，用户主动开启）。
  每 30s 检测一次——端口有 dsh web 但**不在 tmux 托管**（如普通终端里起的）→
  自动迁入 tmux。任何方式启动的 dsh web，关终端都不再影响。看门狗**只迁移
  运行中的 web，绝不主动启动停止的 web**；用 `watchdog-status` / `watchdog-off`
  管理。

### v2.0.4（迁移竞态修复）

- 🔧 `start` 自动接管（普通终端里的 dsh web → tmux）现在**先建空 tmux 会话**，
  等旧进程停止、端口释放后才在托管会话里拉起。原来新实例立即启动、和旧进程抢
  端口（EADDRINUSE），失败会被 run-loop 计入 3 次熔断。
- ✅ 已用假进程 + 无害启动命令端到端实测：空会话 → 旧进程被杀 → 端口释放 →
  托管会话内启动成功。

### v2.0.3（remove 单源防护）

- 🔒 `dsh-web remove <pkg>` 现在**拒绝由 `dsh plugin` 管理的插件**（在
  `dsh.profile.bundles` 中）并引导走 `dsh plugin --profile web remove <pkg>`。
  旧回退路径只删依赖、不删 bundle 条目（ghost bundle），现在从源头挡住。
  卸载路径同样贯彻「每个插件只有一个主人」。

### v2.0.2（跨来源单源加固）

- 🛡️ **跨来源重复检测与自愈**——「duplicate loader entry id」崩溃（同一插件既在
  `dsh.profile.bundles` 又被热装写进 patch 层）现在会被预防并自动修复：
  - `dsh-web repair` 新增诊断 0：bundles 声明的 entry id ∩ patch 层行 → 移除
    patch 层重复行（bundle 侧为权威）并同步 `dsh-web-hot.state.json`。
  - `dsh-web preflight`（boot 前自检）——`start`/`restart` 拉起前自动执行；
    外部把已热装插件收编进 bundles（如 `dsh plugin add`）后，下次启动不会再崩。
  - `dsh-web-hot` 启动自愈——state.json 中记录的热装包若已被
    `dsh.profile.bundles` 收编 → 自动让位（删 patch 行 + 清 state +
    include.update 热卸载），覆盖运行期漂移 / HMR 重载。
- 🩹 补记 v2.0.1 的 `repair` / `health-check` / 自动备份（当时 README 未同步）。

### v2.0.1（repair / health-check / 自动备份）

- 🛠️ `dsh-web repair`：同文件重复 id 去重、ghost bundle 移除、state.json 与
  patch 层对齐；改配置前自动备份（保留最近 10 份）。
- 🩺 `dsh-web health-check`：端口 + 配置树（`--dump-config`）双检查——区分
  「进程问题」还是「配置问题」。
- 🔒 热装拒绝已在 `dsh.profile.bundles` 中的插件（热装侧防重复挂载）。

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

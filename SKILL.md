---
name: dsh-web-restart
description: >
  安全地托管与重启 DeepSeek Harness Web（dsh web）。当 DSH 出现「必须重启才能生效」
  的变更时使用：安装/卸载/更新插件（bundle 层变更）、修改 profile 配置
  （cordis.patch.yml）、升级 dsh 本体（npm 全局包）。通过 tmux 托管 + tmux server
  独立执行延迟重启，避免「杀掉 dsh web 进程 = 杀掉正在其中运行的 agent 会话」导致
  重启命令自身中断。Use when the user asks to restart dsh web after installing or
  removing plugins, after editing profile config (cordis.patch.yml), after upgrading
  the dsh package, when dsh web needs to run persistently without a terminal, or when
  dsh web is down and needs to be brought back up inside tmux.
version: 1.1.6
license: MIT
metadata:
  dsh:
    tags: [dsh, deepseek-harness, tmux, restart, plugin, upgrade, config, web, operations]
---

# dsh-web-restart — 安全重启 DSH Web

## 背景：为什么「重启 dsh web」是个坑

DSH 是「一切皆插件」的框架：以下变更**必须重启 dsh web 才能生效**（bundle 树/配置
在启动时合成，没有热重载）：

1. **装/卸/更新插件**（`dsh plugin --profile web add|remove|update ...`）— bundle 层变更
2. **修改 profile 配置**（`~/.dsh/profiles/web/cordis.patch.yml`）— 用户 patch 层
3. **dsh 本体升级**（`npm install -g @deepseek-ai/dsh@latest`）— 新版本进程

**不需要重启的**（热加载/自动生效）：skill 增改（Chokidar 实时监视）、AGENTS.md
修改（touch 驱动）、已装插件源码改动（HMR）。

难点在于：**dsh web 进程本身承载着正在运行的 agent 会话**。如果同步执行
「kill 进程 → 重新启动」，等于杀掉当前执行命令的宿主，命令会当场中断（表现为
"做了很多轮都没完成"）。

## 正确姿势（核心原理）

用 **tmux 托管 dsh web**，并通过 **tmux server 独立执行延迟重启**：

```bash
# 让 tmux server 在 3 秒后执行：停旧进程 → 重新拉起
tmux run-shell -b "sleep 3; tmux send-keys -t dsh-web C-c; sleep 2; tmux send-keys -t dsh-web 'dsh web' Enter"
```

- `tmux run-shell -b` 由 **tmux server（独立守护进程）** 执行，不依赖 dsh web 存活。
- 即使调用方（agent 会话 / 终端）随 dsh web 被杀，**重启依然会完成**。
- 对比：`nohup ... &` 的后台进程会在调用方回合结束时被清理，**不可靠**。

## 约定

| 项 | 值 | 环境变量覆盖 |
|---|---|---|
| tmux 会话名 | `dsh-web` | `DSH_WEB_SESSION` |
| 端口 | `3080` | `DSH_WEB_PORT` |
| 启动命令 | `dsh web` | `DSH_CMD` |
| 日志 | `~/.dsh/logs/dsh-web.log`、`auto-restart.log` | `DSH_LOG_DIR` |

## tmux 依赖自动处理

本 skill 依赖 tmux，但**不需要对方预先安装**：

- 每次执行 `dsh-web.sh` 时，若检测到 `tmux` 不在 PATH，会自动调用
  `scripts/install-tmux.sh` 尝试安装（支持 Homebrew / apt / dnf / yum /
  pacman / apk / zypper，macOS、Linux 均可）。
- `install.sh` 一键安装时也会顺带检测并安装 tmux。
- 若自动安装失败（如缺 sudo 权限），脚本会给出各平台手动安装命令，不阻塞使用提示。

## 操作步骤

### 首次使用（dsh web 还没托管进 tmux）— 全自动，无需手动 tmux

直接跑 `start` 或 `restart` 即可，脚本会自动检测三种情况并处理：

1. **dsh web 正在普通终端运行**（端口有监听但无 tmux 会话）→ 自动执行「迁入 tmux」：
   由 tmux server 延迟执行「停旧进程 → 在托管会话里拉起」，用户无需手动
   `tmux new -s dsh-web "dsh web"`。
2. **完全没有 dsh web 在跑** → 自动创建 tmux 会话并启动。
3. **已在 tmux 托管** → 正常重启。

```bash
bash <skill_dir>/scripts/dsh-web.sh start     # 启动/自动接管
bash <skill_dir>/scripts/dsh-web.sh restart   # 重启/自动接管（agent 装完插件后推荐）
```

> 也就是说：**别人拿到 skill 后不需要先手动跑任何 tmux 命令**，
> `start` / `restart` 会自己完成「无 tmux 就装、没托管就接管、托管了就重启」。
> （手动 `tmux new -s dsh-web "dsh web"` 仍是可用的备选方式，但不是必需。）

**会话名不叫 `dsh-web` 也没关系**：脚本找不到 `dsh-web` 会话时，会自动发现
「托管了 dsh web」的任意会话（判定：端口有监听 + 某 pane 前台是 node），
然后对该会话执行操作。所以对方用 `0`、`mysession` 等任意名字托管也能工作。

### 首次使用：确保 hot-plugin（dsh-web-hot）已安装（agent 自动补装）

热装（免重启）依赖宿主插件 `dsh-web-hot`。**如果用户是通过 `npx skills add`
装的本 skill，hot-plugin 不会被自动装进 profile**（skills CLI 只拷文件）。
agent 应主动补装：

1. 检查 profile 是否已挂载 hot-plugin：
   ```bash
   grep -q "dsh-web-hot" ~/.dsh/profiles/web/package.json 2>/dev/null \
     && echo present || echo missing
   ```
   （或直接调用 `dsh-web.sh status`，观察输出是否有热装提示）
2. 若缺失，自动补装（`<skill_dir>` 是本 skill 的 base directory）：
   ```bash
   dsh plugin --profile web add "link:<skill_dir>/hot-plugin"
   ```
3. **把用户要装的插件一起装上，一次重启搞定**：如果用户当前正要求装某个插件，
   不要"补装 → 重启 → 再热装"分两步。先 `pnpm add <用户要的插件>`（或
   `dsh plugin add`），再一次性安全重启——hot-plugin 和用户插件同时生效，
   只让用户刷新一次。
4. 之后 `dsh-web install/remove` 自动走免重启热装。

> 若补装失败（如 pnpm 缺失），**降级为安全重启**——功能依然完整，只是
> 装插件要走 `restart` 而不是免重启。不要因此阻塞用户的插件安装请求。

> **`dsh-web` 命令缺失时补装**：本 skill 内部一律用 `<skill_dir>/scripts/dsh-web.sh`
> 绝对路径，不依赖 PATH 命令；但若用户想在终端直接用 `dsh-web xxx`（如
> `dsh-web session`），需要 `install.sh --bin-only` 装命令（会自动把 bin 目录
> 加进 PATH）。发现用户 `command -v dsh-web` 为空时，可代为执行补装。

### 装完插件后：优先热装（免重启），失败才重启

**装/卸插件优先用 `install`/`remove`（热装免重启）**：

```bash
bash <skill_dir>/scripts/dsh-web.sh install <spec>   # 热装，免重启
bash <skill_dir>/scripts/dsh-web.sh remove <pkg>     # 热卸，免重启
```

- 若 dsh-web-hot 插件已加载（`install.sh` 会自动装，或 agent 按上面步骤补装），
  走**免重启热装**——pnpm add + 写 patch 层 + include.update 热应用，用户无感。
- **`remove` 对 CLI 管理的插件会拒绝**（目标在 `dsh.profile.bundles` 中）：热卸必
  失败，回退只删依赖会留 ghost bundle——此时提示改用
  `dsh plugin --profile web remove <pkg>`，不要绕过。
- 若热装不可用（插件未加载 / 变更无法热应用），**自动回退安全重启**。
- **模块代码级更新**（改插件源码后重装）无法热应用（Node require 缓存），
  必然回退重启——这是结构性限制，不是 bug。

**其他场景（改配置 / 升级本体 / 迁移）才用 `restart`**：

```bash
bash <skill_dir>/scripts/dsh-web.sh restart
```

脚本会用 tmux run-shell 排定延迟重启，然后**告诉用户「5-8 秒后刷新页面」**。
不需要用户手动跑任何终端命令。

> **对用户统一说 `install`/`remove`（装插件）和 `restart`（其余）**：装/卸插件时
> 优先给用户"免重启"体验；`reload`/`upgrade` 只是 agent 内部的语义化别名——当
> 场景明确（改配置 → reload；升级 → upgrade）时用它更精准，但不要把这些
> 差异抛给用户去记。

> **重启前自动自检（preflight）**：`restart`/`start` 会在拉起新进程前自动执行
> preflight——若某插件同时存在于 `dsh.profile.bundles` 与 patch 层（如外部
> `dsh plugin add` 收编了之前热装的插件），会自动移除 patch 层重复行并同步
> state，防止下次启动 `duplicate loader entry id` 崩溃。已经崩了就用
> `dsh-web repair` 一条命令自动修（改前自动备份）。

### 改完 profile 配置后生效（reload）

```bash
bash <skill_dir>/scripts/dsh-web.sh reload
```

改 `~/.dsh/profiles/web/cordis.patch.yml` 等 profile 配置后，配置只在下次启动时
合成，必须重启；`reload` 与 `restart` 等价，但语义明确是"配置变更后生效"。

### 升级 dsh 本体后生效（upgrade）

```bash
bash <skill_dir>/scripts/dsh-web.sh upgrade
```

自动检测安装方式（npm 全局 / pnpm 全局），执行 `@deepseek-ai/dsh@latest` 升级，
然后自动重启加载新版本。非 npm/pnpm 安装（源码、其他方式）时只提示手动升级。

### 查看状态 / 停止 / 彻底退出 / 进入排查

```bash
bash <skill_dir>/scripts/dsh-web.sh status   # 会话 / 端口 / PID / 日志
bash <skill_dir>/scripts/dsh-web.sh stop     # 停止（Ctrl-C；托管会话保留，restart 快速恢复）
bash <skill_dir>/scripts/dsh-web.sh quit     # 彻底退出：停止 + 关闭托管会话 + 清理痕迹，不再挂后台
bash <skill_dir>/scripts/dsh-web.sh attach   # tmux attach 进去看实时日志
```

> `stop` 与 `quit`：stop 只是停 dsh web（run-loop 识别 Ctrl-C 不重启，但 tmux
> 托管还在，`restart` 能秒回）；quit 是"不干了"的出口——连托管会话一起关掉，
> 系统里不留任何 dsh web 进程/会话。quit 后若看门狗还在运行会提示（它不会
> 自动重启已停止的 web；彻底禁用用 `dsh-web watchdog-off`）。

### 看门狗：任何方式启动都自动托管（可选，默认关）

```bash
bash <skill_dir>/scripts/dsh-web.sh watchdog-on     # 启用：launchd 每 30s 检测未托管的 dsh web 并自动迁入 tmux
bash <skill_dir>/scripts/dsh-web.sh watchdog-status # 状态
bash <skill_dir>/scripts/dsh-web.sh watchdog-off    # 关闭
```

看门狗只迁移**运行中**的 web，绝不主动启动停止的 web。启用后，普通终端里直接
`dsh web` 起的实例也会在 30s 内被自动迁入 tmux——关终端不再影响。仅 macOS
（Linux systemd timer 后续支持）。

## 本工具是「重启服务」，不是「热重载」

必须先说清这个定位，避免误用：

- **热重载（Hot Reload）**：进程不重启，运行中替换模块/配置。DSH 对
  skill 增改（Chokidar 监视）、AGENTS.md（touch 驱动）、插件源码改动（HMR）、
  settings.yaml / 凭据（Chokidar 热发布）、agent preset（无缓存发现）都是热重载。
- **重启服务（Service Restart）**：杀进程重新启动，整个应用重新初始化。
  DSH 对**插件 bundle 层、profile patch 层、本体版本**这三类变更**设计上就是
  启动时合成**，没有热重载路径，必须重启。

本工具做的是**重启服务**：它不提供热重载，而是把"必须重启才能生效的变更"
变得**安全、自动、不掉线**（用 tmux server 独立执行延迟重启，避免杀掉 agent 宿主）。

> **为什么它不是热重载（试金石）**：热重载的判据是「正在运行的 agent 回合
> **无感继续**」。本工具做不到——agent 住在 dsh web 进程里，重启必然中断回合、
> 断开连接，需要用户刷新页面。它只是把**手动重启**变成**自动重启**（用户操作从
> "敲命令"降级为"刷新页面"），底层依然是"杀进程 → 新进程"，不是"进程不死"。

> 判断标准：**能热重载的不归它管**（skill/AGENTS.md/settings/凭据/preset 的变更
> 直接生效）；**必须重启的归它管**（装插件/改 profile 配置/升级本体）。

## 边界（务必向用户说明）

- **终端全部关闭不影响**：tmux server 是独立守护进程，终端只是客户端，detach 后
  会话与 dsh web 继续运行，自动重启照常可用。
- **重启电脑 / `tmux kill-server` 后**：一切重新开始，需要用户重新打开 dsh web。
  **用任何习惯的方式都行**：`dsh-web.sh start` 最省事（一步建 tmux + 启动 + 托管）；
  直接 `dsh web`（或 `tmux new -s dsh-web "dsh web"`）也可以——第一次 `restart`
  会自动迁入 tmux（多一次自动迁移，之后全自动）。这不是"重建会话"，就是正常重新启动。
- **MCP 连接故障恢复**：MCP 服务器配置（settings 分节）是热重载的，不需要本工具；
  但**已建立的 MCP 连接**若断线且重连被禁用，DSH 源码提示 "reload the plugin or
  restart the Host to reconnect"——这是**故障恢复**场景（连接断了连不上），
  不是配置变更场景。遇到 MCP 工具注册失败/连不上时，可用 `dsh-web.sh restart`
  重启 Host 恢复连接。

## 踩过的坑（避免重蹈）

1. **同步执行重启脚本** → 杀掉宿主进程，命令中断。✅ 改用 `tmux run-shell -b`。
2. **`nohup ... &` 排定后台任务** → 调用方回合结束时被清理，不执行。✅ 改用 tmux server。
3. **杀掉 tmux 会话本身**（`tmux kill-session`）→ 失去托管，需重新 start。
4. **会话名不一致** → `tmux send-keys -t <错误名字>` 找不到会话；统一用 `dsh-web`。
5. **GitHub tarball URL 装插件** → pnpm 锁文件缺 integrity 字段，后续安装全失败；
   用 `github:owner/repo#ref` git spec 代替。
6. **npm 12 升级时 install-scripts 被拦截** → `upgrade` 时若遇到原生模块（如
   node-pty）报错，按 npm 提示执行 `npm install -g --allow-scripts=...` 或
   `npm config set allow-scripts=... --location=user` 放行一次；dsh 本体升级通常不受影响。
7. **同一插件双挂载（跨来源重复）** → 既在 `dsh.profile.bundles`（`dsh plugin`
   管理）又被热装写进 cordis.patch.yml → 下次启动 `duplicate loader entry id`
   崩溃。✅ `start`/`restart` 已自动 preflight 清理；已崩则 `dsh-web repair`
   一条命令自动修（bundle 侧为权威，patch 层让位）。
8. **`dsh-web remove` 卸载 CLI 管理的插件** → 回退只 `pnpm remove` 不删 bundle
   条目 → ghost bundle（条目在、依赖没了）。✅ 已加单源防护：目标在
   `dsh.profile.bundles` 中会直接拒绝并提示用 `dsh plugin --profile web remove`。
9. **迁移时新实例抢端口** → `migrate_into_tmux` 原实现先 `create_session`
   （立即启动 dsh web）再杀旧进程 → EADDRINUSE 反复失败、run-loop 熔断。
   ✅ 已改为：先建空 tmux 会话 → 停旧进程 → 等端口释放 → preflight → 再拉起。
10. **「自动接管」默认是有条件的**：普通终端里的 dsh web 需要跑一次 `dsh-web
    start`/`restart` 才会被迁入 tmux；从不跑脚本直接关终端，进程会随终端退出
    （SIGHUP）。✅ 可选 `dsh-web watchdog-on` 启用 launchd 看门狗后即「真·自动」：
    任何方式启动都会在 30s 内被迁入 tmux，关终端不影响。

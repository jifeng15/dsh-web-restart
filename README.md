# dsh-web-restart

> 让 DSH 需要重启才能生效的变更（装插件 / 改配置 / 升级本体）自动安全重启，不掉线、不用手动敲 tmux。

## 一眼看懂：它能做什么 / 不能做什么

| ✅ **能** | ❌ **不能** |
|---|---|
| 装完插件后**自动重启** dsh web，你**不用手动敲任何命令** | agent 重启后**无缝继续对话**——重启会短暂断开，需你刷新页面（结构性限制） |
| 改完 profile 配置（cordis.patch.yml）后 `reload` 生效 | 让 dsh web 在**不重启**的情况下加载插件/配置（bundle 树启动时合成，必须重启） |
| `upgrade` 升级 dsh 本体并自动重启 | 重启电脑后自动恢复（需要你重新 `dsh-web start` 一次） |
| 没装 tmux？**自动帮你装**（macOS/Linux 主流包管理器） | 在 dsh web **崩溃**时自动拉起（只处理正常重启） |
| dsh web 跑在普通终端？**自动迁入 tmux** 托管 | skill 增改、AGENTS.md 修改等（这些**本来就是热加载的**，不需要它） |
| 会话名不叫 `dsh-web`？**自动找到**实际托管会话 | — |
| 终端窗口全关，dsh web **照常运行**、随时可重启 | — |

**一句话**：DSH 需要重启才能生效的变更（**装插件、改 profile 配置、升级本体**），它负责安全自动重启并让 dsh web 常驻；你只需要在页面断开后刷新一下。

## 30 秒上手

```bash
git clone <本仓库> && cd dsh-web-restart
bash install.sh          # 装 skill + 命令行 + （如缺）tmux

dsh-web status           # 看一眼当前状态
dsh-web restart          # 装完插件后一键安全重启
dsh-web reload           # 改完 profile 配置后重启生效
dsh-web upgrade          # 升级 dsh 本体并自动重启
```

agent 装完插件会自动调用 `dsh-web restart`，你只需**刷新页面**。

## 它解决什么问题

DSH 有三类变更**必须重启 `dsh web` 才能生效**：装/卸/更新插件（bundle 层）、修改 profile 配置（cordis.patch.yml）、升级 dsh 本体。但 dsh web 进程本身承载着 agent——**同步执行重启 = 杀掉宿主 = 命令当场中断**（表现为"做了很多轮都没完成"）。本工具用 tmux 托管 + tmux server 独立执行延迟重启，绕开这个死结。

## 命令

```bash
dsh-web start      # 启动/自动接管（无会话则创建，未托管则迁入 tmux）
dsh-web restart    # 安全自动重启（装插件后）
dsh-web reload     # 改完 profile 配置后重启生效
dsh-web upgrade    # 升级 dsh 本体并自动重启
dsh-web stop       # 停止
dsh-web status     # 查看会话/端口/PID/日志
dsh-web attach     # 进入 tmux 排查
```

## 约定与边界

| 项 | 默认值 | 覆盖 |
|---|---|---|
| tmux 会话名 | `dsh-web`（找不到时自动发现） | `DSH_WEB_SESSION` |
| 端口 | `3080` | `DSH_WEB_PORT` |
| 启动命令 | `dsh web` | `DSH_CMD` |

- 终端全关不影响：tmux server 是守护进程，detach 后继续运行。
- 重启电脑 / `tmux kill-server` 后：重新 `dsh-web start` 即可（正常重新启动，不是"重建"）。
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

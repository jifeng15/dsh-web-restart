---
name: dsh-web-restart
description: >
  安全地托管与重启 DeepSeek Harness Web（dsh web）。当需要重启 dsh web 以让
  新安装的插件 bundle 生效时使用：通过 tmux 托管 + tmux server 独立执行延迟重启，
  避免「杀掉 dsh web 进程 = 杀掉正在其中运行的 agent 会话」导致重启命令自身中断。
  Use when the user asks to restart dsh web after installing plugins, when dsh web
  needs to run persistently without a terminal, when a plugin install requires a
  restart to activate, or when dsh web is down and needs to be brought back up
  inside tmux.
version: 1.0.0
license: MIT
metadata:
  dsh:
    tags: [dsh, deepseek-harness, tmux, restart, plugin, web, operations]
---

# dsh-web-restart — 安全重启 DSH Web

## 背景：为什么「重启 dsh web」是个坑

DSH 是「一切皆插件」的框架：**安装新插件（`dsh plugin --profile web add ...`）后，
必须重启 dsh web 才能让新 bundle 层生效**（bundle 清单在启动时合成，HMR 只热更新
「已装插件源码改动」，不覆盖「新增 bundle 层」）。

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

## 操作步骤

### 首次托管（dsh web 还没跑在 tmux 里）

```bash
# 方式一：用配套脚本
bash <skill_dir>/scripts/dsh-web.sh start

# 方式二：手动一行
tmux new -s dsh-web "dsh web"
```

### 装完插件后自动重启（agent 推荐调用）

```bash
bash <skill_dir>/scripts/dsh-web.sh restart
```

脚本会用 tmux run-shell 排定延迟重启，然后**告诉用户「5-8 秒后刷新页面」**。
不需要用户手动跑任何终端命令。

### 查看状态 / 停止 / 进入排查

```bash
bash <skill_dir>/scripts/dsh-web.sh status   # 会话 / 端口 / PID / 日志
bash <skill_dir>/scripts/dsh-web.sh stop     # Ctrl-C 停止
bash <skill_dir>/scripts/dsh-web.sh attach   # tmux attach 进去看实时日志
```

## 边界（务必向用户说明）

- **终端全部关闭不影响**：tmux server 是独立守护进程，终端只是客户端，detach 后
  会话与 dsh web 继续运行，自动重启照常可用。
- **重启电脑 / `tmux kill-server` 后**：一切重新开始，需要用户手动重新进入
  （`tmux new -s dsh-web "dsh web"` 或 `dsh-web.sh start`）。这不是"重建会话"，
  就是正常重新启动。

## 踩过的坑（避免重蹈）

1. **同步执行重启脚本** → 杀掉宿主进程，命令中断。✅ 改用 `tmux run-shell -b`。
2. **`nohup ... &` 排定后台任务** → 调用方回合结束时被清理，不执行。✅ 改用 tmux server。
3. **杀掉 tmux 会话本身**（`tmux kill-session`）→ 失去托管，需重新 start。
4. **会话名不一致** → `tmux send-keys -t <错误名字>` 找不到会话；统一用 `dsh-web`。
5. **GitHub tarball URL 装插件** → pnpm 锁文件缺 integrity 字段，后续安装全失败；
   用 `github:owner/repo#ref` git spec 代替。

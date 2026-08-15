# dsh-web-restart

> 安全地托管与一键重启 DeepSeek Harness Web（dsh web）——装完插件后无需手动重启，也不会"重启即自杀"。

## 问题

DSH（DeepSeek Harness）是"一切皆插件"的框架：**装新插件后必须重启 `dsh web` 才能让新 bundle 生效**。但 dsh web 进程本身承载着正在运行的 agent 会话——**同步执行重启 = 杀掉宿主 = 命令当场中断**（表现为"做了很多轮都没完成"）。

## 解法

用 **tmux 托管 dsh web** + 通过 **tmux server 独立执行延迟重启**：

```bash
tmux run-shell -b "sleep 3; tmux send-keys -t dsh-web C-c; sleep 2; tmux send-keys -t dsh-web 'dsh web' Enter"
```

tmux server 是独立守护进程，**不依赖 dsh web 存活**——即使调用方随 dsh web 被杀，重启依然完成。

## 安装

```bash
git clone <本仓库> && cd dsh-web-restart
bash install.sh
```

安装后：
- Skill → `~/.agents/skills/dsh-web-restart/`（agent 自动加载，装完插件自动帮你重启）
- 命令行 → `~/bin/dsh-web`

> **无需预装 tmux**：安装时（`install.sh`）会自动检测，缺失则用
> `scripts/install-tmux.sh` 自动安装（支持 macOS Homebrew 与主流 Linux 包管理器）；
> 每次运行 `dsh-web` 时也会防呆检测。自动安装失败会提示各平台手动命令。

## 使用

```bash
dsh-web start      # 启动（无 tmux 会话则自动创建）
dsh-web restart    # 安全自动重启（推荐给 agent 调用）
dsh-web stop       # 停止
dsh-web status     # 查看会话/端口/PID/日志
dsh-web attach     # 进入 tmux 排查
```

## 约定与边界

| 项 | 默认值 | 覆盖 |
|---|---|---|
| tmux 会话名 | `dsh-web` | `DSH_WEB_SESSION` |
| 端口 | `3080` | `DSH_WEB_PORT` |
| 启动命令 | `dsh web` | `DSH_CMD` |

- 终端全关不影响：tmux server 是守护进程，detach 后继续运行，自动重启照常。
- 重启电脑 / `tmux kill-server` 后：正常重新进入即可（`dsh-web start`），不是"重建会话"。

## 踩过的坑

1. 同步重启 = 杀宿主进程 = 命令中断 → 用 `tmux run-shell -b`
2. `nohup ... &` 排定后台任务会被调用方回合清理 → 用 tmux server
3. GitHub tarball URL 装插件会让 pnpm 锁文件缺 integrity → 用 `github:owner/repo#ref`

## License

MIT

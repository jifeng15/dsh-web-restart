#!/usr/bin/env bash
#
# dsh-web — DeepSeek Harness Web 托管管理脚本（tmux 版）
#
# 解决的问题：dsh web 是「一切皆插件」的宿主进程，装完插件后需要重启才能让
# 新 bundle 生效。但如果用同步方式执行重启（kill 进程后再启动），会连累
# 正在 dsh web 里运行的 agent 会话一起中断。正确姿势是用 tmux 托管 dsh web，
# 并通过 tmux server 独立执行延迟重启——tmux server 不依赖 dsh web 存活，
# 即使调用方（agent 会话）随 dsh web 被杀，重启依然会完成。
#
# 用法：
#   dsh-web.sh start    启动 dsh web（无 tmux 会话则自动创建）
#   dsh-web.sh restart  安全自动重启（推荐给 agent 调用，由 tmux server 执行）
#   dsh-web.sh stop     停止 dsh web
#   dsh-web.sh status   查看状态（会话 / 端口 / PID）
#   dsh-web.sh attach   进入 tmux 会话（手动排查用）
#
# 约定：
#   - tmux 会话名：dsh-web（可用 DSH_WEB_SESSION 覆盖）
#   - 端口：3080（可用 DSH_WEB_PORT 覆盖）
#   - 启动命令：dsh web（可用 DSH_CMD 覆盖）
#
# 边界：
#   - 终端全部关闭不影响：tmux server 是独立守护进程，detach 后继续运行。
#   - 重启电脑 / tmux kill-server 后需手动重新 `tmux new -s dsh-web "dsh web"`。
#
set -u

SESSION="${DSH_WEB_SESSION:-dsh-web}"
PORT="${DSH_WEB_PORT:-3080}"
DSH_CMD="${DSH_CMD:-dsh web}"
LOG_DIR="${DSH_LOG_DIR:-$HOME/.dsh/logs}"

log()  { echo "==> $*"; }
die()  { echo "!! $*" >&2; exit 1; }

# 确保 tmux 可用：缺失时尝试自动安装（install-tmux.sh 与脚本同目录）
require_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    return 0
  fi
  local installer
  installer="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-tmux.sh"
  log "未检测到 tmux，尝试自动安装..."
  if [ -f "${installer}" ]; then
    bash "${installer}"
  else
    die "缺少 install-tmux.sh，且 tmux 不可用；请先手动安装 tmux"
  fi
  command -v tmux >/dev/null 2>&1 || die "tmux 安装失败，请手动安装后重试"
  log "tmux 就绪"
}

is_listening() { lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; }

has_session()  { tmux has-session -t "${SESSION}" 2>/dev/null; }

wait_port() {
  local n="${1:-20}"
  for _ in $(seq 1 "${n}"); do
    if is_listening; then log "端口 ${PORT} 已就绪"; return 0; fi
    sleep 1
  done
  log "等待 ${PORT} 超时（${n}s）"; return 1
}

cmd_start() {
  mkdir -p "${LOG_DIR}"
  if has_session; then
    log "tmux 会话 ${SESSION} 已存在（若 dsh web 未运行，请用 restart）"
  else
    log "创建 tmux 会话 ${SESSION} 并启动 dsh web"
    tmux new-session -d -s "${SESSION}" "exec ${DSH_CMD} 2>&1 | tee ${LOG_DIR}/dsh-web.log"
  fi
  wait_port 20
  log "访问 http://127.0.0.1:${PORT}"
}

cmd_restart() {
  mkdir -p "${LOG_DIR}"
  if ! has_session; then
    log "无 tmux 会话 ${SESSION}，改为直接启动"
    cmd_start
    return $?
  fi
  # 关键：由 tmux server 独立执行延迟重启。
  # - 调用方（agent 会话 / 终端）即使被杀，tmux server 仍会完成 C-c 与重新启动。
  # - 不要在括号内用 $SESSION 外层展开出问题：tmux run-shell 以 server 环境执行。
  log "由 tmux server 排定自动重启（约 5-8 秒完成，页面会短暂断开）"
  tmux run-shell -b "sleep 3; tmux send-keys -t ${SESSION} C-c; sleep 2; tmux send-keys -t ${SESSION} '${DSH_CMD}' Enter; echo \"dsh-web restarted \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
  log "已排定；请稍后刷新 http://127.0.0.1:${PORT}"
}

cmd_stop() {
  if ! has_session; then
    log "无 tmux 会话 ${SESSION}，无需停止"
    return 0
  fi
  log "向 tmux 会话 ${SESSION} 发送 Ctrl-C"
  tmux send-keys -t "${SESSION}" C-c
  sleep 2
  if is_listening; then
    log "端口 ${PORT} 仍在监听（可能正在优雅退出，可再执行一次 stop）"
  else
    log "dsh web 已停止"
  fi
}

cmd_status() {
  echo "--- tmux 会话 ---"
  if has_session; then
    tmux list-panes -t "${SESSION}" -F "会话: #{session_name} / pane: #{pane_id} / 前台: #{pane_current_command}"
    tmux ls -F "attached: #{session_attached} created: #{session_created_string}"
  else
    echo "无会话 ${SESSION}"
  fi
  echo "--- 端口 ${PORT} ---"
  if is_listening; then
    lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN | tail -1
  else
    echo "无监听"
  fi
  echo "--- 日志 ---"
  ls -la "${LOG_DIR}"/dsh-web.log "${LOG_DIR}"/auto-restart.log 2>/dev/null || echo "（暂无日志）"
}

cmd_attach() {
  has_session || die "无会话 ${SESSION}，请先 start"
  exec tmux attach -t "${SESSION}"
}

require_tmux

case "${1:-}" in
  start)   cmd_start ;;
  restart) cmd_restart ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  attach)  cmd_attach ;;
  *) die "用法: dsh-web.sh {start|restart|stop|status|attach}" ;;
esac

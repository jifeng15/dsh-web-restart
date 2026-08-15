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

# 找出占用端口的进程 PID（未被 tmux 托管的旧 dsh web）
port_pid() { lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -1; }

# 判断某 PID 是否属于某 tmux 会话的某个 pane 进程树（用 pgrep 遍历，避免依赖 ps）
pid_in_session_tree() {
  local pid="$1" pane_pids="$2" cur children
  # 从 pane_pids 各 PID 向下 BFS 子进程，看是否覆盖 pid
  local queue="${pane_pids}"
  while [ -n "${queue}" ]; do
    cur="${queue%% *}"
    queue="${queue#* }"
    [ -z "${cur}" ] && continue
    if [ "${cur}" = "${pid}" ]; then return 0; fi
    children="$(pgrep -P "${cur}" 2>/dev/null | tr '\n' ' ')"
    queue="${queue} ${children}"
  done
  return 1
}

# 解析目标会话：默认 dsh-web；若不存在，自动发现「托管了 dsh web」的会话。
# 判定条件（组合启发式，误判率极低）：
#   ① 端口 ${PORT} 有进程监听（dsh web 一定监听该端口）
#   ② 某 tmux 会话的 pane 前台命令是 node（dsh web 是 node 进程）
# 这样别人用任意会话名（如 0 / mysession）托管 dsh web 也能被自动找到。
resolve_session() {
  if has_session; then return 0; fi
  local pid s cmd pane_pids
  pid="$(port_pid)"
  [ -z "${pid}" ] && return 1   # 端口无监听，无从发现
  # 优先精确进程树关联（部分环境可用）
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    pane_pids="$(tmux list-panes -t "${s}" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')"
    if pid_in_session_tree "${pid}" "${pane_pids}"; then
      log "未找到会话 ${SESSION}，自动使用托管 dsh web 的会话: ${s}"
      SESSION="${s}"
      return 0
    fi
  done
  # 兜底启发式：pane 前台是 node + 端口有监听
  for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
    cmd="$(tmux list-panes -t "${s}" -F '#{pane_current_command}' 2>/dev/null | head -1)"
    if [ "${cmd}" = "node" ]; then
      log "未找到会话 ${SESSION}，自动使用托管 dsh web 的会话: ${s}（启发式）"
      SESSION="${s}"
      return 0
    fi
  done
  return 1
}

# 创建托管会话（不立即启动 dsh web，避免与旧进程端口冲突）
create_session() {
  tmux new-session -d -s "${SESSION}" "exec ${DSH_CMD} 2>&1 | tee ${LOG_DIR}/dsh-web.log"
}

# 自动接管：检测到「无 tmux 会话 + 端口已有 dsh web」时，
# 由 tmux server 延迟执行「停旧进程 → 在托管会话里拉起」，无需用户手动 tmux。
migrate_into_tmux() {
  local pid
  pid="$(port_pid)"
  if [ -z "${pid}" ]; then
    return 1  # 端口无监听，无需迁移
  fi
  log "检测到未被托管的 dsh web（PID ${pid}，端口 ${PORT}），正在自动迁入 tmux..."
  create_session
  # 由 tmux server 执行，调用方（agent/终端）被杀也不影响迁移完成
  tmux run-shell -b "sleep 2; kill -TERM ${pid} 2>/dev/null; sleep 2; tmux send-keys -t ${SESSION} C-c; sleep 1; tmux send-keys -t ${SESSION} '${DSH_CMD}' Enter; echo \"dsh-web migrated \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
  log "已排定迁移：旧进程停止后 dsh web 将在 tmux 会话 ${SESSION} 中重启（5-8 秒）"
  return 0
}

# 等待端口由「新托管进程」接管：先等旧进程退出（端口短暂释放），再等新进程监听。
# 若直接等端口就绪，会误判为旧进程仍在监听。返回 0=新进程已就绪。
wait_port_migrated() {
  local pid_old pid_new n=25
  pid_old="$(port_pid)"
  # 阶段一：等旧进程退出（最多 10s）
  for _ in $(seq 1 10); do
    if [ -z "$(port_pid)" ]; then log "旧进程已退出，端口释放"; break; fi
    sleep 1
  done
  # 阶段二：等新进程接管（最多 15s）
  for _ in $(seq 1 15); do
    pid_new="$(port_pid)"
    if [ -n "${pid_new}" ] && [ "${pid_new}" != "${pid_old}" ]; then
      log "新进程（PID ${pid_new}）已接管端口 ${PORT}"
      return 0
    fi
    sleep 1
  done
  log "等待新进程接管超时"; return 1
}

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
  resolve_session || true   # 找不到 dsh-web 时自动发现托管会话
  if has_session; then
    log "tmux 会话 ${SESSION} 已存在（若 dsh web 未运行，请用 restart）"
  elif migrate_into_tmux; then
    wait_port_migrated
    log "迁移完成：dsh web 已托管在 tmux 会话 ${SESSION}"
  else
    log "创建 tmux 会话 ${SESSION} 并启动 dsh web"
    create_session
    wait_port 20
  fi
  log "访问 http://127.0.0.1:${PORT}"
}

cmd_restart() {
  mkdir -p "${LOG_DIR}"
  resolve_session || true   # 找不到 dsh-web 时自动发现托管会话
  if ! has_session; then
    log "无 tmux 会话 ${SESSION}"
    if migrate_into_tmux; then
      wait_port_migrated
      log "迁移完成；请稍后刷新 http://127.0.0.1:${PORT}"
      return 0
    fi
    log "改为直接启动"
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
  resolve_session || true   # 找不到 dsh-web 时自动发现托管会话
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
  resolve_session || true   # 找不到 dsh-web 时自动发现托管会话
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
  resolve_session || true   # 找不到 dsh-web 时自动发现托管会话
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

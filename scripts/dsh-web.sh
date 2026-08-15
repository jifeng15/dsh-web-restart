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
#   dsh-web.sh start     启动 dsh web（无 tmux 会话则自动创建）
#   dsh-web.sh restart   安全自动重启（推荐给 agent 调用，由 tmux server 执行）
#   dsh-web.sh reload    改完 profile 配置（cordis.patch.yml）后重启生效（= restart）
#   dsh-web.sh upgrade   升级 dsh 本体（npm 全局）后自动重启生效
#   dsh-web.sh stop      停止 dsh web
#   dsh-web.sh status    查看状态（会话 / 端口 / PID）
#   dsh-web.sh attach    进入 tmux 会话（手动排查用）
#   dsh-web.sh report-port  把实际端口写入 last-port.txt 并发系统通知
#   dsh-web.sh autostart-on  启用开机自启（launchd/systemd，默认关闭，用户自选）
#   dsh-web.sh autostart-off 关闭开机自启
#   dsh-web.sh autostart-status  查看自启状态
#
# 需要重启的 DSH 变更场景（本脚本的适用范围）：
#   1. 装/卸/更新插件（bundle 层变更）→ restart
#   2. 修改 profile 配置（cordis.patch.yml / package.json bundles）→ reload
#   3. dsh 本体升级（npm 全局包）→ upgrade
#   （skill 增改、AGENTS.md 修改、插件源码改动是热加载的，不需要重启）
#
# 约定：
#   - tmux 会话名：dsh-web（可用 DSH_WEB_SESSION 覆盖）
#   - 端口：自动发现（DSH_WEB_PORT 显式 > 进程命令行 --port > node 监听扫描 > 默认 3080）
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

# 找出疑似 dsh web 的进程 PID 列表（ps 优先，pgrep 兜底；macOS 的 pgrep -f 对带空格模式不可靠）
dsh_web_pids() {
  local pids
  pids="$(ps -axo pid,command 2>/dev/null | awk '$2 ~ /dsh$/ || $0 ~ /dsh web/ {print $1}' | head -5)"
  if [ -z "${pids}" ]; then
    pids="$(pgrep -f "dsh web" 2>/dev/null | head -5)"
  fi
  printf '%s' "${pids}"
}

# 自动发现 dsh web 实际监听的端口（用户可能用 --port 8080 或 --port 0 随机端口启动）。
# 优先级：DSH_WEB_PORT 显式配置 > 从 dsh web 进程命令行解析 --port/-p > 进程监听端口 > node 监听扫描 > 默认 3080
discover_port() {
  [ -n "${DSH_WEB_PORT:-}" ] && { PORT="${DSH_WEB_PORT}"; log "使用显式端口: ${PORT}"; return 0; }
  local pids pid cmdline p
  pids="$(dsh_web_pids)"
  # 方式一：从进程命令行解析 --port/-p（ps 在部分环境可用）
  for pid in ${pids}; do
    cmdline="$(ps -p "${pid}" -o command= 2>/dev/null)"
    [ -z "${cmdline}" ] && continue
    p="$(printf '%s' "${cmdline}" | sed -nE 's/.*--port[= ]+([0-9]+).*/\1/p; s/.*-p[= ]+([0-9]+).*/\1/p' | head -1)"
    # --port 0 表示"让 OS 选随机端口"，无法从命令行得知实际端口，继续走扫描
    if [ -n "${p}" ] && [ "${p}" != "0" ]; then
      PORT="${p}"
      log "从进程命令行解析端口: ${PORT}（PID ${pid}）"
      return 0
    fi
  done
  # 方式二：优先用 dsh web PID 精确查其监听端口
  for pid in ${pids}; do
    p="$(lsof -nP -a -p "${pid}" -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {split($9,a,":"); print a[length(a)]}' | head -1)"
    if [ -n "${p}" ]; then
      PORT="${p}"
      log "从 dsh web 进程（PID ${pid}）监听端口解析: ${PORT}"
      return 0
    fi
  done
  # 方式三：扫描 node 进程监听的端口（lsof 全量，兜底）
  p="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '$1=="node" && $9 ~ /127\.0\.0\.1:|localhost:/ {split($9,a,":"); print a[length(a)]}' | head -1)"
  if [ -n "${p}" ]; then
    PORT="${p}"
    log "从 node 监听端口解析: ${PORT}"
    return 0
  fi
  PORT="${PORT:-3080}"
  log "未发现自定义端口，使用默认: ${PORT}"
}

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

# 崩溃自动重启的包装命令（若开启且 run-loop.sh 存在）
crash_loop_cmd() {
  local loop_dir
  loop_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ "${DSH_CRASH_RESTART:-1}" = "1" ] && [ -f "${loop_dir}/run-loop.sh" ]; then
    printf '%s' "${loop_dir}/run-loop.sh -- ${DSH_CMD}"
  else
    printf '%s' "${DSH_CMD}"
  fi
}

# 创建托管会话（不立即启动 dsh web，避免与旧进程端口冲突）。
# 崩溃自动重启：默认开启（DSH_CRASH_RESTART=1），用 run-loop.sh 循环包装；
# 连续崩溃 3 次熔断停止，避免坏配置无限空转。设 DSH_CRASH_RESTART=0 关闭。
create_session() {
  local loop_cmd
  loop_cmd="$(crash_loop_cmd)"
  if [[ "${loop_cmd}" == *"run-loop.sh"* ]]; then
    log "崩溃自动重启已开启（run-loop，连续 3 次熔断）"
  fi
  tmux new-session -d -s "${SESSION}" "exec ${loop_cmd} 2>&1 | tee ${LOG_DIR}/dsh-web.log"
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
  tmux run-shell -b "sleep 2; kill -TERM ${pid} 2>/dev/null; sleep 2; tmux send-keys -t ${SESSION} C-c; sleep 1; tmux send-keys -t ${SESSION} '$(crash_loop_cmd)' Enter; echo \"dsh-web migrated \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
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

# 端口报告：start/restart 完成后，把实际端口写入 last-port.txt。
# 通知策略：默认端口（3080）不通知（用户都知道）；非默认端口（被占用/随机）
# 才发系统通知告知实际端口——尤其开机自启是无人值守场景，用户需要知道连哪。
report_port() {
  # 重新探测一次实际端口（wait_port 后端口应已稳定）
  discover_port >/dev/null 2>&1 || true
  local portfile="${LOG_DIR}/last-port.txt"
  printf '%s\n' "${PORT}" > "${portfile}"
  log "实际端口已记录: ${portfile} → ${PORT}"
  # 默认端口不通知；仅非默认端口通知
  if [ "${PORT}" = "${DSH_DEFAULT_PORT:-3080}" ]; then
    log "端口为默认值（${PORT}），跳过通知"
    return 0
  fi
  # macOS 通知中心（osascript）；Linux 用 notify-send（存在时）
  local msg="dsh web 端口 ${PORT}（非默认）→ http://127.0.0.1:${PORT}"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg}\" with title \"dsh-web-restart\"" >/dev/null 2>&1 || true
    log "已发送 macOS 通知（非默认端口 ${PORT}）"
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "dsh-web-restart" "${msg}" >/dev/null 2>&1 || true
    log "已发送系统通知（非默认端口 ${PORT}）"
  fi
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
  report_port
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
  tmux run-shell -b "sleep 3; tmux send-keys -t ${SESSION} C-c; sleep 2; tmux send-keys -t ${SESSION} '$(crash_loop_cmd)' Enter; echo \"dsh-web restarted \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
  # 延迟探测重启后的实际端口（等 6 秒新进程接管），写入 last-port.txt 并通知
  ( sleep 6; "${BASH_SOURCE[0]}" report-port ) >/dev/null 2>&1 &
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

# 修改 profile 配置（cordis.patch.yml 等）后重启生效。配置在启动时合成，
# 没有热重载，必须重启；本命令与 restart 等价，但语义更清晰。
cmd_reload() {
  log "profile 配置变更需要重启才能合成进 bundle 树，正在重启..."
  cmd_restart
}

# 升级 dsh 本体（npm 全局包）后自动重启生效。
# 支持：npm 全局安装（标准）；其他安装方式（pnpm/源码）给出提示，仅重启。
cmd_upgrade() {
  local pkg_manager="npm" bin_path bin_real
  bin_path="$(command -v dsh 2>/dev/null)"
  if [ -z "${bin_path}" ]; then
    die "未找到 dsh 命令，请先安装 @deepseek-ai/dsh"
  fi
  # 解析符号链接拿真实路径，再判断是否为 npm 全局安装
  if command -v readlink >/dev/null 2>&1; then
    bin_real="$(readlink -f "${bin_path}" 2>/dev/null || readlink "${bin_path}" 2>/dev/null || echo "${bin_path}")"
  else
    bin_real="${bin_path}"
  fi
  # 检测是否为 npm 全局安装（/node_modules/@deepseek-ai/dsh 路径特征）
  if [[ "${bin_real}" == *"node_modules/@deepseek-ai/dsh"* ]]; then
    pkg_manager="npm"
  elif [ -n "${PNPM_HOME:-}" ] && [[ "${bin_real}" == *"${PNPM_HOME}"* ]]; then
    pkg_manager="pnpm"
  else
    pkg_manager="other"
  fi
  log "dsh 安装方式: ${pkg_manager}（$(dsh --version 2>/dev/null)）"
  case "${pkg_manager}" in
    npm)
      log "执行: npm install -g @deepseek-ai/dsh@latest"
      npm install -g @deepseek-ai/dsh@latest 2>&1 | tail -3 || die "npm 升级失败"
      ;;
    pnpm)
      log "执行: pnpm add -g @deepseek-ai/dsh@latest"
      pnpm add -g @deepseek-ai/dsh@latest 2>&1 | tail -3 || die "pnpm 升级失败"
      ;;
    *)
      log "检测到非 npm/pnpm 安装（${bin_path}），无法自动升级；请手动升级后运行 restart"
      return 0
      ;;
  esac
  log "升级完成: $(dsh --version 2>/dev/null)"
  log "正在重启 dsh web 以加载新版本..."
  cmd_restart
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

# 开机自启：默认关闭，用户主动启用。
# macOS → launchd LaunchAgent；Linux → systemd user unit。
# 自启只负责「开机后自动 dsh-web start」，端口由 report-port 在非默认时通知。
AUTOSTART_LABEL="com.dsh-web.restart"

autostart_status() {
  if [ "$(uname -s)" = "Darwin" ]; then
    [ -f "$HOME/Library/LaunchAgents/${AUTOSTART_LABEL}.plist" ] && echo "已启用（launchd）" || echo "未启用"
  else
    [ -f "$HOME/.config/systemd/user/${AUTOSTART_LABEL}.service" ] && echo "已启用（systemd）" || echo "未启用"
  fi
}

autostart_on() {
  local script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dsh-web.sh"
  if [ "$(uname -s)" = "Darwin" ]; then
    local dir="$HOME/Library/LaunchAgents"
    mkdir -p "${dir}"
    cat > "${dir}/${AUTOSTART_LABEL}.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AUTOSTART_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script}</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict>
</plist>
EOF
    launchctl unload "${dir}/${AUTOSTART_LABEL}.plist" 2>/dev/null || true
    launchctl load "${dir}/${AUTOSTART_LABEL}.plist" 2>&1 && log "开机自启已启用（launchd）：登录时自动 dsh-web start"
  else
    local dir="$HOME/.config/systemd/user"
    mkdir -p "${dir}"
    cat > "${dir}/${AUTOSTART_LABEL}.service" <<EOF
[Unit]
Description=dsh-web-restart autostart
[Service]
Type=oneshot
ExecStart=/bin/bash ${script} start
RemainAfterExit=yes
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload 2>/dev/null
    systemctl --user enable --now "${AUTOSTART_LABEL}.service" 2>&1 && log "开机自启已启用（systemd）"
  fi
}

autostart_off() {
  if [ "$(uname -s)" = "Darwin" ]; then
    local plist="$HOME/Library/LaunchAgents/${AUTOSTART_LABEL}.plist"
    if [ -f "${plist}" ]; then
      launchctl unload "${plist}" 2>/dev/null || true
      rm -f "${plist}"
      log "开机自启已关闭（launchd）"
    else
      log "未启用开机自启"
    fi
  else
    local svc="$HOME/.config/systemd/user/${AUTOSTART_LABEL}.service"
    if [ -f "${svc}" ]; then
      systemctl --user disable --now "${AUTOSTART_LABEL}.service" 2>/dev/null || true
      rm -f "${svc}"
      systemctl --user daemon-reload 2>/dev/null
      log "开机自启已关闭（systemd）"
    else
      log "未启用开机自启"
    fi
  fi
}

require_tmux
discover_port

case "${1:-}" in
  start)   cmd_start ;;
  restart) cmd_restart ;;
  reload)  cmd_reload ;;
  upgrade) cmd_upgrade ;;
  report-port) report_port ;;
  autostart-on) autostart_on ;;
  autostart-off) autostart_off ;;
  autostart-status) autostart_status ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  attach)  cmd_attach ;;
  *) die "用法: dsh-web.sh {start|restart|reload|upgrade|stop|status|attach}" ;;
esac

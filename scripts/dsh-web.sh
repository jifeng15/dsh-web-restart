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
#   dsh-web.sh stop      停止 dsh web（Ctrl-C；tmux 托管保留，可 restart 恢复）
#   dsh-web.sh quit      彻底退出（停止 + 关闭托管会话 + 清理痕迹，不再挂在后台）
#   dsh-web.sh status    查看状态（会话 / 端口 / PID）
#   dsh-web.sh attach    进入 tmux 会话（手动排查用）
#   dsh-web.sh report-port  把实际端口写入 last-port.txt 并发系统通知
#   dsh-web.sh health-check  检查端口与配置树（区分进程问题/配置问题）
#   dsh-web.sh repair        修复配置（同文件重复 id / ghost bundle / 跨来源重复）
#   dsh-web.sh preflight     boot 前自检（start/restart 自动执行；清跨来源重复）
#   dsh-web.sh watchdog-on   启用 launchd 看门狗（每 30s 检测未托管的 dsh web 并自动迁入 tmux）
#   dsh-web.sh watchdog-off  关闭看门狗
#   dsh-web.sh watchdog-status  查看看门狗状态
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

# profile 目录：DSH_PROFILE_DIR 显式覆盖 > $HOME/.dsh/profiles/${PROFILE:-web}
profile_dir() {
  if [ -n "${DSH_PROFILE_DIR:-}" ]; then
    printf '%s' "${DSH_PROFILE_DIR}"
  else
    printf '%s' "$HOME/.dsh/profiles/${PROFILE:-web}"
  fi
}

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

# 创建托管会话并立即启动 dsh web（仅用于「无旧进程」的全新启动：此时端口空闲，
# 直接拉起即可）。迁移场景（旧进程占着端口）走 migrate_into_tmux 的空会话 +
# 延迟拉起，避免 EADDRINUSE 竞态。
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
  # 先建「空」tmux 会话（不启动 dsh web）：若立即启动，新实例会与旧进程抢端口
  # （EADDRINUSE），run-loop 会把失败计入 3 次熔断，迁移可能以空转/挂掉收场。
  # 空会话等旧进程退出、端口释放后再拉起。
  tmux new-session -d -s "${SESSION}" || return 1
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dsh-web.sh"
  # 由 tmux server 独立执行：停旧进程 → 等端口释放 → preflight → 在托管会话拉起。
  # 调用方（agent/终端）被杀也不影响迁移完成。
  tmux run-shell -b "sleep 2; kill -TERM ${pid} 2>/dev/null; sleep 2; tmux send-keys -t ${SESSION} C-c; sleep 1; for i in \$(seq 1 12); do lsof -nP -iTCP:${PORT} -sTCP:LISTEN -t >/dev/null 2>&1 || break; sleep 1; done; ${self} preflight >/dev/null 2>&1 || true; tmux send-keys -t ${SESSION} '$(crash_loop_cmd)' Enter; echo \"dsh-web migrated \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
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
  cmd_preflight   # boot 前自检：先清跨来源重复（duplicate loader entry id 的根源），再启动
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
  # - 重启前先跑 preflight（boot 前自检，清跨来源重复），防止新进程因
  #   duplicate loader entry id 起不来——自检由 tmux server 独立执行，
  #   调用方被杀也不影响。
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dsh-web.sh"
  log "由 tmux server 排定自动重启（会话 ${SESSION}，约 5-8 秒完成，页面会短暂断开）"
  tmux run-shell -b "sleep 3; tmux send-keys -t ${SESSION} C-c; sleep 2; ${self} preflight >/dev/null 2>&1 || true; tmux send-keys -t ${SESSION} '$(crash_loop_cmd)' Enter; echo \"dsh-web restarted \$(date '+%H:%M:%S')\" >> ${LOG_DIR}/auto-restart.log"
  # 延迟健康检查：等重启完成后验证端口与配置树，区分进程/配置问题
  ( sleep 10; "${BASH_SOURCE[0]}" health-check ) >/dev/null 2>&1 &
  # 延迟探测重启后的实际端口（等 6 秒新进程接管），写入 last-port.txt 并通知
  ( sleep 6; "${BASH_SOURCE[0]}" report-port ) >/dev/null 2>&1 &
  log "已排定；请稍后刷新 http://127.0.0.1:${PORT}"
}

# 健康检查：验证 dsh web 是否真的起来了，以及配置树是否健康。
# 区分「进程问题」与「配置问题」——配置损坏时重启多少次都会失败，应提示修配置。
cmd_health_check() {
  local port_ok=no config_ok=no
  if is_listening; then port_ok=yes; fi
  if dsh --profile "${PROFILE:-web}" --dump-config >/dev/null 2>&1; then config_ok=yes; fi
  if [ "${port_ok}" = "yes" ] && [ "${config_ok}" = "yes" ]; then
    log "健康检查通过：端口 ${PORT} 就绪，配置树正常"
    return 0
  fi
  # 有异常：报告具体是哪个问题
  if [ "${port_ok}" != "yes" ]; then
    log "⚠️ 端口 ${PORT} 未就绪——进程可能未启动"
  fi
  if [ "${config_ok}" != "yes" ]; then
    log "⚠️ 配置树校验失败（--dump-config 报错）——可能是配置损坏（如 cordis.patch.yml 重复行 / YAML 错误 / ghost bundle / 跨来源重复）"
    log "   → 用 'dsh-web repair' 诊断并修复配置，不要反复 restart"
  fi
  if [ "${port_ok}" != "yes" ] && [ "${config_ok}" != "yes" ]; then
    log "   → 端口和配置都异常，优先修配置（repair），再重启"
  fi
  return 1
}

# 自动备份 profile 配置（cordis.patch.yml / state.json / pnpm-workspace.yaml）。
# 任何修改配置的操作前调用；备份到 profile/backups/，保留最近 N 份。
config_backup() {
  local profile_dir backup_dir ts
  profile_dir="$(profile_dir)"
  backup_dir="${profile_dir}/backups"
  mkdir -p "${backup_dir}"
  ts="$(date +%Y%m%d-%H%M%S)"
  for f in cordis.patch.yml dsh-web-hot.state.json pnpm-workspace.yaml; do
    if [ -f "${profile_dir}/${f}" ]; then
      cp "${profile_dir}/${f}" "${backup_dir}/${f}.${ts}.bak"
    fi
  done
  # 只保留最近 10 份，避免无限堆积
  ls -1t "${backup_dir}"/cordis.patch.yml.*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f
  ls -1t "${backup_dir}"/dsh-web-hot.state.json.*.bak 2>/dev/null | tail -n +11 | xargs -r rm -f
  log "配置已备份到 ${backup_dir}（时间戳 ${ts}）"
}

# 跨来源重复检测：bundles 声明的 entry id（读各 bundle 的 dsh.bundle.patch）
# ∩ cordis.patch.yml 的 entry id。输出冲突 id（换行分隔）；无冲突输出为空。
# 这是「duplicate loader entry id」崩溃的最常见根源：同一插件既在
# dsh.profile.bundles（dsh plugin CLI 管理，自带 patch 自动挂载）又被
# dsh-web-hot 热装写进了用户 patch 层 → loader 里出现两个同名 entry。
cross_source_conflicts() {
  local profile_dir pkg_file patch_file
  profile_dir="$(profile_dir)"
  pkg_file="${profile_dir}/package.json"
  patch_file="${profile_dir}/cordis.patch.yml"
  [ -f "${pkg_file}" ] || return 0
  [ -f "${patch_file}" ] || return 0
  python3 - "${pkg_file}" "${profile_dir}" "${patch_file}" <<'PYEOF'
import json, os, re, sys
pkg_path, profile_dir, patch_path = sys.argv[1], sys.argv[2], sys.argv[3]
ID_RE = re.compile(r'^\s*-?\s*id:\s*([A-Za-z0-9._-]+)')

def entry_ids(path):
    ids = set()
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                m = ID_RE.match(line)
                if m:
                    ids.add(m.group(1))
    except OSError:
        pass
    return ids

try:
    with open(pkg_path, encoding='utf-8') as f:
        pkg = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
bundles = (pkg.get('dsh') or {}).get('profile', {}).get('bundles') or []
bundle_ids = set()
for name in bundles:
    if not isinstance(name, str):
        continue
    pkg_dir = os.path.join(profile_dir, 'node_modules', name)
    try:
        with open(os.path.join(pkg_dir, 'package.json'), encoding='utf-8') as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        continue
    patch_rel = ((manifest.get('dsh') or {}).get('bundle') or {}).get('patch')
    if not patch_rel:
        continue
    bundle_ids |= entry_ids(os.path.join(pkg_dir, patch_rel))
conflicts = sorted(bundle_ids & entry_ids(patch_path))
if conflicts:
    print('\n'.join(conflicts))
PYEOF
}

# 修复跨来源重复：以 bundles 侧为权威（CLI 管理的持久来源），从
# cordis.patch.yml 移除冲突行并同步 state.json。改前自动备份。
# 返回 0=无需修复或已修复；1=修复失败。
fix_cross_source() {
  local profile_dir pkg_file patch_file state_file conflicts
  profile_dir="$(profile_dir)"
  pkg_file="${profile_dir}/package.json"
  patch_file="${profile_dir}/cordis.patch.yml"
  state_file="${profile_dir}/dsh-web-hot.state.json"
  [ -f "${pkg_file}" ] || return 0
  [ -f "${patch_file}" ] || return 0
  conflicts="$(cross_source_conflicts)"
  [ -n "${conflicts}" ] || return 0
  log "检测到跨来源重复 entry id：$(printf '%s' "${conflicts}" | tr '\n' ' ')"
  log "  → 同一插件同时存在于 dsh.profile.bundles 与 cordis.patch.yml（duplicate loader entry id 的根源）"
  log "  → 以 bundles 侧为权威，从 cordis.patch.yml 移除重复行；以后增删改走 'dsh plugin --profile web add|remove'"
  config_backup
  python3 - "${patch_file}" "${state_file}" ${conflicts} <<'PYEOF'
import json, re, sys
patch_path, state_path = sys.argv[1], sys.argv[2]
bad = set(sys.argv[3:])
ID_RE = re.compile(r'^\s*-?\s*id:\s*([A-Za-z0-9._-]+)')

with open(patch_path, encoding='utf-8') as f:
    lines = f.readlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^\s*-\s*insert:\s*$', line):
        j = i + 1
        block = [line]
        while j < len(lines) and (lines[j].startswith(' ') or lines[j].startswith('\t')):
            block.append(lines[j]); j += 1
        # 按条目分组（每个 `- ` 开头的行为一个新条目），删除 id 冲突的条目
        entries, current = [], []
        for bl in block[1:]:
            if re.match(r'^\s*-\s+', bl):
                if current:
                    entries.append(current)
                current = [bl]
            else:
                current.append(bl)
        if current:
            entries.append(current)
        kept = []
        for ent in entries:
            m = ID_RE.match(ent[0])
            if m and m.group(1) in bad:
                continue
            kept.extend(ent)
        if kept:
            out.append(block[0])
            out.extend(kept)
        i = j
    elif ID_RE.match(line):
        m = ID_RE.match(line)
        if m.group(1) in bad:
            i += 1
            # 连同行删除（如 `- id: foo` 下的 `  disabled: true` 续行）
            while i < len(lines) and (lines[i].startswith(' ') or lines[i].startswith('\t')) and not re.match(r'^\s*-\s', lines[i]):
                i += 1
            continue
        out.append(line)
        i += 1
    else:
        out.append(line)
        i += 1

# 若 patch 层已无任何行，写回标准空数组（保持 yaml 合法）
if not any(re.match(r'^\s*-\s', l) for l in out):
    out = ['# Rows managed by dsh-web-hot — edit or remove freely, or uninstall the bundle.\n', '[]\n']
with open(patch_path, 'w', encoding='utf-8') as f:
    f.writelines(out)
print('已从 cordis.patch.yml 移除冲突 id 所在行:', sorted(bad))

# 同步 state.json：移除被收编 bundle 的记录与 disables 键
try:
    with open(state_path, encoding='utf-8') as f:
        state = json.load(f)
except (OSError, ValueError):
    state = {'bundles': [], 'disables': {}}
if isinstance(state, dict):
    state.setdefault('bundles', [])
    state.setdefault('disables', {})
    state['bundles'] = [b for b in state['bundles'] if not (set(b.get('rowIds', [])) & bad)]
    for k in list(state['disables']):
        if k in bad:
            del state['disables'][k]
    with open(state_path, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print('已同步 dsh-web-hot.state.json（移除被收编 bundle 的记录）')
PYEOF
  local rc=$?
  if [ "${rc}" != "0" ]; then
    log "⚠️ 跨来源修复失败（rc=${rc}）——请手动检查 ${patch_file}，备份在 ${profile_dir}/backups/"
    return 1
  fi
  log "✅ 跨来源重复已修复：patch 层让位，bundle 侧保持挂载（重启后正常合成）"
}

# boot 前自检：修复跨来源重复，防止下一次启动因 duplicate loader entry id 崩溃。
# start/restart 自动调用；也可手动跑。始终退出 0（自愈失败不阻塞启动）。
cmd_preflight() {
  fix_cross_source
  return 0
}

# 修复配置：诊断常见损坏并尝试自动修复，改前自动备份，修复后验证。
cmd_repair() {
  local profile_dir patch_file state_file pkg_file config_ok=no
  profile_dir="$(profile_dir)"
  patch_file="${profile_dir}/cordis.patch.yml"
  state_file="${profile_dir}/dsh-web-hot.state.json"
  pkg_file="${profile_dir}/package.json"

  log "=== dsh-web repair：诊断配置 ==="
  # 诊断 0：跨来源重复（bundles 声明的 entry id ∩ patch 层）——duplicate
  # loader entry id 崩溃的最常见根源，无论配置树是否正常都先查并修。
  fix_cross_source || return 1

  if dsh --profile "${PROFILE:-web}" --dump-config >/dev/null 2>&1; then config_ok=yes; fi
  if [ "${config_ok}" = "yes" ]; then
    log "配置树正常（--dump-config 通过）——无需修复"
    return 0
  fi
  log "⚠️ 配置树校验失败，开始诊断..."

  # 备份当前（可能损坏的）配置
  config_backup

  # 诊断 1：cordis.patch.yml 重复 id
  if [ -f "${patch_file}" ]; then
    local dup
    dup="$(grep -oE '^\s*-?\s*id:\s*[A-Za-z0-9._-]+' "${patch_file}" 2>/dev/null | awk '{print $NF}' | sort | uniq -d | head -1)"
    if [ -n "${dup}" ]; then
      log "诊断：cordis.patch.yml 存在重复 id『${dup}』（duplicate loader entry id 的根源）"
      # 备份后去重：保留每个 id 第一次出现，删除后续重复行所在 insert
      log "修复：去重重复 id 的行..."
      python3 - "${patch_file}" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
seen = set()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    # 处理 insert 块（`- insert:` 后跟缩进子行）
    if re.match(r'^\s*-\s*insert:\s*$', line):
        j = i + 1
        block = [line]
        while j < len(lines) and (lines[j].startswith(' ') or lines[j].startswith('\t')):
            block.append(lines[j]); j += 1
        first_id = None
        for bl in block:
            m = re.match(r'^\s*-?\s*id:\s*([A-Za-z0-9._-]+)', bl)
            if m:
                first_id = m.group(1)
                break
        if first_id and first_id in seen:
            i = j  # 跳过整个重复块（含块头），不残留空块
            continue
        if first_id:
            seen.add(first_id)
        out.extend(block)
        i = j
    else:
        out.append(line)
        i += 1
with open(path, 'w') as f:
    f.writelines(out)
print("已去重（整块删除重复 id 的 insert，含块头）")
PYEOF
    fi
  fi

  # 诊断 2：ghost bundle（bundles 指向不存在的包）
  if [ -f "${pkg_file}" ]; then
    python3 - "${pkg_file}" "${profile_dir}" <<'PYEOF'
import json, sys, os
pkg_path, profile_dir = sys.argv[1], sys.argv[2]
with open(pkg_path) as f:
    pkg = json.load(f)
bundles = pkg.get('dsh', {}).get('profile', {}).get('bundles', [])
ghosts = []
for name in bundles:
    if not os.path.exists(os.path.join(profile_dir, 'node_modules', name)):
        # 官方 in-box bundle 可能在 dsh 安装闭包，这里只报告明显缺失的
        ghosts.append(name)
if ghosts:
    print("诊断：ghost bundle（bundles 列出但 node_modules 缺失）:", ghosts)
    pkg['dsh']['profile']['bundles'] = [b for b in bundles if b not in ghosts]
    with open(pkg_path, 'w') as f:
        json.dump(pkg, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print("已从 bundles 移除:", ghosts)
PYEOF
  fi

  # 诊断 3：state.json 与配置不一致 → 若 cordis.patch.yml 为空则清空 state
  if [ -f "${state_file}" ] && [ -f "${patch_file}" ]; then
    if ! grep -qE '^\s*-?\s*insert:|^\s*-?\s*id:' "${patch_file}" 2>/dev/null; then
      log "诊断：cordis.patch.yml 无有效行（热装管理器无挂载）——清空 state.json 对齐"
      echo '{"bundles": [], "disables": {}}' > "${state_file}"
      log "已清空 dsh-web-hot.state.json"
    fi
  fi

  # 修复后验证
  log "修复完成，重新验证配置树..."
  if dsh --profile "${PROFILE:-web}" --dump-config >/dev/null 2>&1; then
    log "✅ 配置树校验通过——可安全重启（dsh-web restart）"
    return 0
  else
    log "⚠️ 仍校验失败——请手动检查 ${patch_file} 或查看 backups/ 回滚"
    log "  备份位置: ${profile_dir}/backups/"
    return 1
  fi
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

# 彻底退出：停 dsh web + 关闭托管会话 + 清理痕迹，让系统里不再有 dsh web 相关
# 进程/会话。与 stop 的区别：stop 只发 Ctrl-C（run-loop 识别信号退出、不重启，
# 但 tmux 会话和 pane 还在）；quit 停完还关掉 tmux 托管会话并清理 crash-count。
cmd_quit() {
  resolve_session || true
  if has_session; then
    log "停止 dsh web（托管会话 ${SESSION}）..."
    tmux send-keys -t "${SESSION}" C-c
    sleep 3
    # 兜底：进程仍在监听（优雅退出慢 / run-loop 重启间隙）→ 直接 TERM
    if is_listening; then
      local pid
      pid="$(port_pid)"
      if [ -n "${pid}" ]; then
        kill -TERM "${pid}" 2>/dev/null && log "已向 PID ${pid} 发送 TERM"
        sleep 2
      fi
    fi
    tmux kill-session -t "${SESSION}" 2>/dev/null
    log "托管会话 ${SESSION} 已关闭"
  else
    if is_listening; then
      local pid
      pid="$(port_pid)"
      log "检测到未托管的 dsh web（PID ${pid}），正在停止..."
      kill -TERM "${pid}" 2>/dev/null
      sleep 2
    else
      log "dsh web 未在运行"
    fi
  fi
  rm -f "${DSH_CRASH_COUNT_FILE:-$HOME/.dsh/logs/crash-count}" 2>/dev/null || true
  if is_listening; then
    log "⚠️ 端口 ${PORT} 仍在监听——请手动检查，或再执行一次 quit"
    return 1
  fi
  log "✅ dsh web 已完全退出（端口 ${PORT} 已释放），不再有托管会话"
  if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist" ]; then
    log "  提示：看门狗仍在运行（每 30s 检测）；它只迁移运行中的 web，不会自动重启已停止的"
    log "        彻底禁用用: dsh-web watchdog-off"
  fi
}

# 修改 profile 配置（cordis.patch.yml 等）后重启生效。配置在启动时合成，
# 没有热重载，必须重启；本命令与 restart 等价，但语义更清晰。
cmd_reload() {
  log "profile 配置变更需要重启才能合成进 bundle 树，正在重启..."
  cmd_restart
}

# 检查 dsh-web-hot 热装路由是否可用（进程内插件已加载）
hot_available() {
  is_listening || return 1
  curl -s -m 3 "http://127.0.0.1:${PORT}/dsh-web-hot/list" 2>/dev/null | grep -q '"ok":true'
}

# 热装/热卸（通过 dsh-web-hot 进程内插件，免重启）
hot_install() { curl -s -m 300 -X POST "http://127.0.0.1:${PORT}/dsh-web-hot/install" -H "content-type: application/json" -d "{\"spec\":\"$1\"}" 2>/dev/null; }
hot_uninstall() { curl -s -m 300 -X POST "http://127.0.0.1:${PORT}/dsh-web-hot/uninstall" -H "content-type: application/json" -d "{\"packageName\":\"$1\"}" 2>/dev/null; }

# 安装插件：优先热装（免重启）；热装不可用或失败时回退安全重启。
cmd_install() {
  local spec="$1" result
  [ -n "${spec}" ] || die "用法: dsh-web install <spec>（npm 包名 / git URL / github:owner/repo）"
  config_backup   # 改配置前自动备份（防损坏可回滚）
  if hot_available; then
    log "检测到热装可用（dsh-web-hot），尝试免重启安装 ${spec}..."
    result="$(hot_install "${spec}")"
    if printf '%s' "${result}" | grep -q '"ok":true'; then
      log "✅ 热装成功（免重启）: $(printf '%s' "${result}" | sed 's/.*"message":"\([^"]*\)".*/\1/')"
      return 0
    fi
    log "热装未成功（$(printf '%s' "${result}" | sed 's/.*"message":"\([^"]*\)".*/\1/' | head -c 80)），回退安全重启安装..."
  else
    log "未检测到热装插件（dsh-web-hot），走安全重启安装..."
  fi
  # 回退：pnpm add + 安全重启
  if ! command -v pnpm >/dev/null 2>&1 && [ -x /opt/homebrew/bin/pnpm ]; then
    export PATH="/opt/homebrew/bin:${PATH}"
  fi
  ( cd ~/.dsh/profiles/web && pnpm add "${spec}" --config.minimumReleaseAge=0 --registry=https://registry.npmjs.org >/dev/null 2>&1 ) \
    || die "pnpm add 失败: ${spec}"
  cmd_restart
}

# 卸载插件：优先热卸；失败回退移除依赖 + 安全重启。
cmd_remove() {
  local pkg="$1" result pkg_file managed
  [ -n "${pkg}" ] || die "用法: dsh-web remove <packageName>"
  config_backup   # 改配置前自动备份（防损坏可回滚）
  # 单源防护：目标在 dsh.profile.bundles 中 = 由 dsh plugin CLI 管理。
  # 此时热卸必失败（state 无记录）；回退 pnpm remove 只删依赖、不删 bundle
  # 条目 → 留下 ghost bundle（条目在、依赖没了），下次启动出问题。
  # 拒绝并引导走 CLI，保持「每个插件只有一个主人」。
  pkg_file="$(profile_dir)/package.json"
  if [ -f "${pkg_file}" ]; then
    managed="$(python3 - "${pkg_file}" "${pkg}" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        pkg = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
bundles = (pkg.get('dsh') or {}).get('profile', {}).get('bundles') or []
if sys.argv[2] in bundles:
    print('cli-managed')
PYEOF
)"
    if [ -n "${managed}" ]; then
      die "「${pkg}」在 dsh.profile.bundles 中（由 dsh plugin CLI 管理）。请用 'dsh plugin --profile web remove ${pkg}' 卸载；走 dsh-web remove 会留下 ghost bundle（bundle 条目在、依赖没了）。"
    fi
  fi
  if hot_available; then
    log "检测到热卸可用（dsh-web-hot），尝试免重启卸载 ${pkg}..."
    result="$(hot_uninstall "${pkg}")"
    if printf '%s' "${result}" | grep -q '"ok":true'; then
      log "✅ 热卸成功（免重启）: $(printf '%s' "${result}" | sed 's/.*"message":"\([^"]*\)".*/\1/')"
      return 0
    fi
    log "热卸未成功（$(printf '%s' "${result}" | sed 's/.*"message":"\([^"]*\)".*/\1/' | head -c 80)），回退安全重启卸载..."
  else
    log "未检测到热装插件（dsh-web-hot），走安全重启卸载..."
  fi
  if ! command -v pnpm >/dev/null 2>&1 && [ -x /opt/homebrew/bin/pnpm ]; then
    export PATH="/opt/homebrew/bin:${PATH}"
  fi
  ( cd ~/.dsh/profiles/web && pnpm remove "${pkg}" --config.minimumReleaseAge=0 >/dev/null 2>&1 ) \
    || log "pnpm remove 失败（可能未安装 ${pkg}）"
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

# 报告当前实际解析到的 tmux 会话名——调试/手动操作前先跑它，
# 避免假设会话名（如假设 dsh-web 而实际是 0）。
cmd_session() {
  resolve_session || true
  if has_session; then
    echo "${SESSION}"
  else
    echo "(无托管 dsh web 的 tmux 会话)"
  fi
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

# launchd 看门狗：默认关闭，用户主动启用。每 30s 检测一次——
# 端口有 dsh web 但不在 tmux 托管 → 自动迁入 tmux（任何方式开启的 dsh web，
# 关终端都不影响）。只迁移运行中的 web，绝不主动启动停止的 web。
WATCHDOG_LABEL="com.dsh-web.watchdog"

watchdog_status() {
  if [ "$(uname -s)" = "Darwin" ]; then
    if [ -f "$HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist" ]; then
      echo "已启用（launchd，每 30s 检测未托管的 dsh web 并自动迁入 tmux）"
    else
      echo "未启用"
    fi
  else
    echo "看门狗当前仅支持 macOS（launchd）；Linux（systemd timer）后续版本支持"
  fi
}

watchdog_on() {
  [ "$(uname -s)" = "Darwin" ] || die "看门狗当前仅支持 macOS（launchd）"
  require_tmux
  local script dir plist
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dsh-web.sh"
  dir="$HOME/Library/LaunchAgents"
  mkdir -p "${dir}"
  plist="${dir}/${WATCHDOG_LABEL}.plist"
  cat > "${plist}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${WATCHDOG_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script}</string>
    <string>watchdog-tick</string>
  </array>
  <key>StartInterval</key><integer>30</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>${HOME}</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>${LOG_DIR}/watchdog.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/watchdog.log</string>
</dict>
</plist>
EOF
  launchctl unload "${plist}" 2>/dev/null || true
  launchctl load "${plist}" 2>&1 && log "看门狗已启用（launchd，每 30s 检测未托管的 dsh web 并自动迁入 tmux）"
}

watchdog_off() {
  local plist="$HOME/Library/LaunchAgents/${WATCHDOG_LABEL}.plist"
  if [ -f "${plist}" ]; then
    launchctl unload "${plist}" 2>/dev/null || true
    rm -f "${plist}"
    log "看门狗已关闭"
  else
    log "看门狗未启用"
  fi
}

# 看门狗单次检测（由 launchd 每 30s 调用；也可手动跑）。
# 端口有 dsh web 但不在 tmux 托管 → 自动迁入 tmux。绝不主动启动停止的 web。
cmd_watchdog_tick() {
  if ! is_listening; then return 0; fi          # web 没在跑 → 无事可做
  if resolve_session >/dev/null 2>&1; then return 0; fi  # 已在 tmux 托管 → 无事可做
  log "watchdog：检测到未托管的 dsh web（端口 ${PORT}），自动迁入 tmux..."
  migrate_into_tmux
  return 0
}


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
  install) cmd_install "${2:-}" ;;
  remove)  cmd_remove "${2:-}" ;;
  repair)  cmd_repair ;;
  health-check) cmd_health_check ;;
  preflight) cmd_preflight ;;
  watchdog-on) watchdog_on ;;
  watchdog-off) watchdog_off ;;
  watchdog-status) watchdog_status ;;
  watchdog-tick) cmd_watchdog_tick ;;
  report-port) report_port ;;
  autostart-on) autostart_on ;;
  autostart-off) autostart_off ;;
  autostart-status) autostart_status ;;
  stop)    cmd_stop ;;
  quit)    cmd_quit ;;
  status)  cmd_status ;;
  session) cmd_session ;;
  attach)  cmd_attach ;;
  *) die "用法: dsh-web.sh {start|restart|install|remove|reload|upgrade|repair|health-check|preflight|watchdog-on|watchdog-off|watchdog-status|stop|quit|status|session|attach}" ;;
esac

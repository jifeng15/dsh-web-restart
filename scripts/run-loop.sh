#!/usr/bin/env bash
#
# run-loop.sh — 在 tmux pane 里循环运行 dsh web，并在崩溃时自动重启（带熔断）。
#
# 设计：
#   - 正常退出（Ctrl-C 主动停止，退出码 130/143 或 SIGINT/SIGTERM）→ 不重启，直接退出。
#   - 非正常退出（崩溃，退出码非 0 且非信号退出）→ 计数 +1；连续崩溃达
#     MAX_CRASHES 次（默认 3）→ 熔断停止，避免坏配置导致无限空转。
#   - 每次「成功启动后正常运行超过 STABLE_SECONDS（默认 60s）」→ 计数清零
#     （证明这次启动是健康的，崩溃熔断只针对连续快速崩溃）。
#
# 用法：run-loop.sh [--max-crashes N] [--stable-seconds N] -- <command...>
#
set -u

MAX_CRASHES=3
STABLE_SECONDS=60
CMD=()

while [ $# -gt 0 ]; do
  case "$1" in
    --max-crashes) MAX_CRASHES="$2"; shift 2 ;;
    --stable-seconds) STABLE_SECONDS="$2"; shift 2 ;;
    --) shift; CMD=("$@"); break ;;
    *) echo "usage: run-loop.sh [--max-crashes N] [--stable-seconds N] -- <cmd...>" >&2; exit 2 ;;
  esac
done

[ "${#CMD[@]}" -gt 0 ] || { echo "run-loop.sh: no command given" >&2; exit 2; }

COUNT_FILE="${DSH_CRASH_COUNT_FILE:-$HOME/.dsh/logs/crash-count}"
mkdir -p "$(dirname "${COUNT_FILE}")"

count=0
if [ -f "${COUNT_FILE}" ]; then
  count="$(cat "${COUNT_FILE}" 2>/dev/null | tr -d '[:space:]')"
  case "${count}" in ''|*[!0-9]*) count=0 ;; esac
fi

echo "run-loop: starting ${CMD[*]} (max-crashes=${MAX_CRASHES}, stable=${STABLE_SECONDS}s, count=${count})"

while true; do
  start_ts="$(date +%s)"
  "${CMD[@]}"
  code=$?

  # 正常信号退出（Ctrl-C / TERM）→ 这是主动停止，不重启
  if [ "${code}" -eq 130 ] || [ "${code}" -eq 143 ]; then
    echo "run-loop: dsh web stopped by signal (${code}), exiting"
    rm -f "${COUNT_FILE}"
    exit 0
  fi

  # 健康运行判定：存活超过 STABLE_SECONDS → 计数清零。
  # --stable-seconds 0 表示禁用健康判定（每次退出都计为崩溃，用于测试/严格模式）。
  now="$(date +%s)"
  if [ "${STABLE_SECONDS}" -gt 0 ] && [ $(( now - start_ts )) -ge "${STABLE_SECONDS}" ]; then
    count=0
    echo "run-loop: healthy run (${now} - ${start_ts} >= ${STABLE_SECONDS}s), crash count reset"
  else
    count=$(( count + 1 ))
    echo "run-loop: crash detected (exit=${code}, count=${count}/${MAX_CRASHES})"
  fi

  if [ "${count}" -ge "${MAX_CRASHES}" ]; then
    echo "run-loop: reached max crashes (${MAX_CRASHES}), giving up. Check dsh config." >&2
    printf '%s\n' "${count}" > "${COUNT_FILE}"
    exit 1
  fi

  printf '%s\n' "${count}" > "${COUNT_FILE}"
  echo "run-loop: restarting dsh web in 2s..."
  sleep 2
done

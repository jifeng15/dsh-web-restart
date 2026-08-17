#!/usr/bin/env bash
#
# install.sh — 一键安装 dsh-web-restart skill 到 ~/.agents/skills/
#
# 用法：
#   bash install.sh             安装到 ~/.agents/skills/dsh-web-restart/
#   bash install.sh --bin-only  只装 dsh-web.sh 到 ~/bin（不加 skill）
#   bash install.sh --no-tmux   跳过 tmux 检测/安装
#   SKILL_DIR=~/custom bash install.sh   自定义目标目录
#
set -u

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${SKILL_DIR:-$HOME/.agents/skills/dsh-web-restart}"
BIN_DIR="${BIN_DIR:-$HOME/bin}"

install_skill() {
  mkdir -p "${DEST_DIR}/scripts"
  cp "${SRC_DIR}/SKILL.md" "${DEST_DIR}/SKILL.md"
  cp "${SRC_DIR}/scripts/dsh-web.sh" "${DEST_DIR}/scripts/dsh-web.sh"
  cp "${SRC_DIR}/scripts/install-tmux.sh" "${DEST_DIR}/scripts/install-tmux.sh"
  # hot-plugin 一并复制，供 dsh-web-hot 本地安装使用
  mkdir -p "${DEST_DIR}/hot-plugin"
  cp "${SRC_DIR}/hot-plugin/package.json" "${DEST_DIR}/hot-plugin/package.json"
  cp "${SRC_DIR}/hot-plugin/cordis.patch.yml" "${DEST_DIR}/hot-plugin/cordis.patch.yml"
  cp "${SRC_DIR}/hot-plugin/index.js" "${DEST_DIR}/hot-plugin/index.js"
  cp "${SRC_DIR}/hot-plugin/manager.js" "${DEST_DIR}/hot-plugin/manager.js"
  chmod +x "${DEST_DIR}/scripts/dsh-web.sh" "${DEST_DIR}/scripts/install-tmux.sh"
  echo "==> Skill 已安装到 ${DEST_DIR}"
  echo "    下次会话 agent 会自动加载；也可手动执行:"
  echo "    bash ${DEST_DIR}/scripts/dsh-web.sh status"
}

install_hot_plugin() {
  # 把 dsh-web-hot 装进 web profile（本地 bundle），提供免重启热装能力。
  # 需要 dsh CLI + pnpm；失败不影响 skill 本身（热装降级为安全重启）。
  if ! command -v dsh >/dev/null 2>&1; then
    echo "!! 未找到 dsh 命令，跳过热装插件安装（dsh-web install 将降级为安全重启）"
    return 0
  fi
  local profile="$HOME/.dsh/profiles/web"
  if [ ! -f "${profile}/package.json" ]; then
    echo "!! 未找到 web profile，跳过热装插件安装"
    return 0
  fi
  echo "==> 安装热装插件 dsh-web-hot 到 web profile..."
  if command -v pnpm >/dev/null 2>&1 || [ -x /opt/homebrew/bin/pnpm ]; then
    local path_pnpm
    if ! command -v pnpm >/dev/null 2>&1; then
      export PATH="/opt/homebrew/bin:${PATH}"
    fi
    dsh plugin --profile web add "link:${DEST_DIR}/hot-plugin" 2>&1 | tail -3
    echo "==> dsh-web-hot 已加入 bundle；重启 dsh web 后热装能力生效"
    echo "    可用: dsh-web restart  （重启后 dsh-web install/remove 自动走热装）"
  else
    echo "!! 未找到 pnpm，跳过热装插件安装（dsh-web install 将降级为安全重启）"
  fi
}

install_bin() {
  mkdir -p "${BIN_DIR}"
  cp "${SRC_DIR}/scripts/dsh-web.sh" "${BIN_DIR}/dsh-web"
  chmod +x "${BIN_DIR}/dsh-web"
  # run-loop.sh 一并安装：从 ~/bin/dsh-web 调用时若同目录没有 run-loop.sh，
  # 托管会退化为「无 run-loop 裸进程」，被看门狗误判误杀（见坑 #13）。
  cp "${SRC_DIR}/scripts/run-loop.sh" "${BIN_DIR}/run-loop.sh"
  chmod +x "${BIN_DIR}/run-loop.sh"
  echo "==> 命令行工具已安装到 ${BIN_DIR}/dsh-web（含 run-loop.sh）"
  # 若 BIN_DIR 不在 PATH：自动写入 shell rc（带标记防重复），避免「命令不存在」
  if ! printf '%s' ":$PATH:" | grep -q ":${BIN_DIR}:"; then
    local marker_found=0 rc
    for rc in "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile"; do
      [ -f "${rc}" ] || continue
      if grep -q "dsh-web-restart: dsh-web" "${rc}" 2>/dev/null; then
        marker_found=1
        break
      fi
    done
    if [ "${marker_found}" = "0" ]; then
      local target_rc="$HOME/.zshrc"
      [ -f "$HOME/.zshrc" ] || target_rc="$HOME/.bash_profile"
      printf '\n# dsh-web-restart: dsh-web 命令\nexport PATH="%s:$PATH"\n' "${BIN_DIR}" >> "${target_rc}"
      echo "==> ${BIN_DIR} 不在 PATH，已自动写入 ${target_rc}（新终端生效）"
      echo "    当前终端可先执行: export PATH=\"${BIN_DIR}:\$PATH\""
    else
      echo "==> ${BIN_DIR} 已在 shell rc 的 PATH 中（新终端生效）"
    fi
  fi
}

ensure_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    echo "==> tmux 已就绪: $(command -v tmux)"
    return 0
  fi
  echo "==> 未检测到 tmux，尝试自动安装..."
  bash "${SRC_DIR}/scripts/install-tmux.sh" || {
    echo "!! tmux 未安装成功。可稍后手动执行: bash ${DEST_DIR}/scripts/install-tmux.sh"
    return 1
  }
}

case "${1:-}" in
  --bin-only) install_bin ;;
  *)
    install_skill
    install_bin
    if [ "${1:-}" != "--no-tmux" ]; then
      ensure_tmux || true
    fi
    if [ "${1:-}" != "--no-hot" ]; then
      install_hot_plugin
    fi
    ;;
esac

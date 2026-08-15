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
  chmod +x "${DEST_DIR}/scripts/dsh-web.sh" "${DEST_DIR}/scripts/install-tmux.sh"
  echo "==> Skill 已安装到 ${DEST_DIR}"
  echo "    下次会话 agent 会自动加载；也可手动执行:"
  echo "    bash ${DEST_DIR}/scripts/dsh-web.sh status"
}

install_bin() {
  mkdir -p "${BIN_DIR}"
  cp "${SRC_DIR}/scripts/dsh-web.sh" "${BIN_DIR}/dsh-web"
  chmod +x "${BIN_DIR}/dsh-web"
  echo "==> 命令行工具已安装到 ${BIN_DIR}/dsh-web"
  echo "    若 ${BIN_DIR} 不在 PATH，请自行加入: export PATH=\"${BIN_DIR}:\$PATH\""
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
    ;;
esac

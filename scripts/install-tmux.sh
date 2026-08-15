#!/usr/bin/env bash
#
# install-tmux.sh — 跨平台安装 tmux（幂等：已装则跳过，支持自动检测包管理器）
#
# 支持：macOS (Homebrew)、Debian/Ubuntu (apt)、Fedora/RHEL (dnf/yum)、
#       Arch (pacman)、Alpine (apk)、openSUSE (zypper)
#
# 用法：
#   bash install-tmux.sh          自动检测并安装
#   bash install-tmux.sh --check  只检测，不安装（供 dsh-web.sh 调用）
#
set -u

say() { echo "==> $*"; }
die() { echo "!! $*" >&2; exit 1; }

have_tmux() { command -v tmux >/dev/null 2>&1; }

# 只检测模式：返回 0=已装 / 1=未装，不输出安装动作
if [ "${1:-}" = "--check" ]; then
  if have_tmux; then
    say "tmux 已安装: $(command -v tmux) ($(tmux -V 2>/dev/null || echo '?'))"
    exit 0
  else
    say "tmux 未安装"
    exit 1
  fi
fi

if have_tmux; then
  say "tmux 已安装: $(command -v tmux) ($(tmux -V 2>/dev/null || echo '?'))，跳过安装"
  exit 0
fi

say "未检测到 tmux，尝试自动安装..."

installed=0

try_brew() {
  command -v brew >/dev/null 2>&1 || return 1
  say "检测到 Homebrew，执行: brew install tmux"
  brew install tmux 2>&1 | tail -3 && installed=1
}

try_apt() {
  command -v apt-get >/dev/null 2>&1 || return 1
  say "检测到 apt（Debian/Ubuntu），执行: sudo apt-get install -y tmux"
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y tmux 2>&1 | tail -3 && installed=1
}

try_dnf() {
  command -v dnf >/dev/null 2>&1 || return 1
  say "检测到 dnf（Fedora/RHEL），执行: sudo dnf install -y tmux"
  sudo dnf install -y tmux 2>&1 | tail -3 && installed=1
}

try_yum() {
  command -v yum >/dev/null 2>&1 || return 1
  say "检测到 yum（CentOS/RHEL），执行: sudo yum install -y tmux"
  sudo yum install -y tmux 2>&1 | tail -3 && installed=1
}

try_pacman() {
  command -v pacman >/dev/null 2>&1 || return 1
  say "检测到 pacman（Arch），执行: sudo pacman -S --noconfirm tmux"
  sudo pacman -S --noconfirm tmux 2>&1 | tail -3 && installed=1
}

try_apk() {
  command -v apk >/dev/null 2>&1 || return 1
  say "检测到 apk（Alpine），执行: sudo apk add tmux"
  sudo apk add tmux 2>&1 | tail -3 && installed=1
}

try_zypper() {
  command -v zypper >/dev/null 2>&1 || return 1
  say "检测到 zypper（openSUSE），执行: sudo zypper install -y tmux"
  sudo zypper install -y tmux 2>&1 | tail -3 && installed=1
}

try_brew || try_apt || try_dnf || try_yum || try_pacman || try_apk || try_zypper || true

if have_tmux; then
  say "tmux 安装成功: $(tmux -V 2>/dev/null)"
  exit 0
fi

die "未能自动安装 tmux。请手动安装后重试：
  macOS:      brew install tmux
  Debian/Ubuntu: sudo apt-get install -y tmux
  Fedora/RHEL:   sudo dnf install -y tmux  (或 yum)
  Arch:       sudo pacman -S tmux
  Alpine:     sudo apk add tmux
  openSUSE:   sudo zypper install tmux"

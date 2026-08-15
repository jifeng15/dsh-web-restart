# dsh-web-restart

> **True hot-loading for dsh web**: after installing plugins, editing config, or upgrading dsh itself, see the effect immediately — no more manually restarting from the command line.

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-yes-2ea44f?logo=deepseek)](https://github.com/topics/dsh-plugin)
[![dsh-skill](https://img.shields.io/badge/dsh--skill-yes-8e44ad?logo=deepseek)](https://github.com/topics/dsh-skill)
[![deepseek-harness](https://img.shields.io/badge/deepseek--harness-yes-4d6bfe)](https://github.com/topics/deepseek-harness)
![License](https://img.shields.io/badge/license-MIT-blue)

**English** | [简体中文](README.zh-CN.md)

## The problem it solves (what we actually hit)

While using **dsh web**, I found that DSH has three kinds of changes that **require a process restart to take effect** — installing/removing/updating plugins (bundle layers are composed at startup), editing profile config (`cordis.patch.yml`), and upgrading the dsh package itself.

Every time, I had to **leave the conversation, go to the command line, re-type `dsh web`**, and refresh the page to see the effect:

- ❌ **Not timely**: can't see plugin effects right after installing
- ❌ **Manual**: even when an agent installed the plugin in conversation, I still had to open a terminal
- ❌ **Fragile**: killing the process directly also kills the running agent session ("many rounds never finished")

**This skill syncs "hot reload" and "hot restart"** — things that DSH already hot-reloads (skills, AGENTS.md, settings) keep hot-reloading; things that **must restart are restarted safely and automatically by the agent**. dsh web becomes truly hot-loadable: install a plugin in conversation, refresh once, and see the effect — **no more manual restarts**.

## Quick Start

Three ways to install, pick any:

**① Install via conversation (recommended)** — say this in a DSH conversation (**include the repo URL** so the agent knows where to install from):

> "**Install https://github.com/jifeng15/dsh-web-restart**"

The agent installs and loads the skill automatically (skills are hot-loaded — ready immediately, no restart needed).

**② One-line install** — in your own terminal:

```bash
npx -y skills add https://github.com/jifeng15/dsh-web-restart -g -y -a universal --copy
```

**③ Clone & manual install** — if you want to inspect the source first:

```bash
git clone https://github.com/jifeng15/dsh-web-restart.git && cd dsh-web-restart
bash install.sh
```

Ready after install (see "Two Usage Scenarios" below).

## Two Usage Scenarios (both supported)

### Scenario A: Via conversation (recommended) — you type nothing

After **installing this skill**, say in conversation "**install plugin XX for me**" (XX = any **other** plugin, e.g. dsh-market) or "**upgrade dsh for me**". The agent will:

1. Load this skill automatically
2. Install the plugin / upgrade dsh
3. **Automatically call** `dsh-web restart` (agent calls the script directly — you never touch the command line)
4. You just **refresh the page** — the new plugin/version takes effect immediately

> For: users who manage plugins through DSH conversations. This is the skill's **primary scenario** — it's designed for agents.

### Scenario B: Manual command line — full control

If you prefer the terminal (e.g. `dsh plugin add` directly, without conversation), **run once after installing a plugin**:

```bash
dsh-web restart    # unified: after installing/removing/updating plugins, editing profile config, or upgrading dsh
dsh-web status     # check status anytime
```

> **One command covers all scenarios**: whether you installed a plugin, edited `cordis.patch.yml`, or upgraded dsh — it's all the same action: safely restart dsh web. So you only need to remember `dsh-web restart`.
>
> **Why the "extra step" is unavoidable**: the skill's "auto-restart" trigger is the **agent** — when you install via conversation, the agent is present and auto-invokes it; but when you install from your own terminal, no agent is involved, so you must run it manually once. **This one-time step is worth it**: it migrates dsh web into tmux hosting, and after that everything (conversation-driven) is fully automatic.
>
> For: CLI users, script automation, and agent-internal calls. All commands **automatically** handle tmux hosting, port discovery, and session discovery — no preparation needed.

## At a Glance: What It Can / Can't Do

| ✅ **Can** | ❌ **Can't** |
|---|---|
| **Auto-restart** dsh web after installing plugins — **no manual commands** (conversation) | Agent **continuing seamlessly** after restart — restart briefly disconnects, you refresh (structural limit) |
| `restart`/`reload` take effect after editing profile config (`cordis.patch.yml`) | Load plugins/config **without restarting the process** (bundle tree is composed at startup; must restart the process — refreshing the page only reconnects, it doesn't load) |
| `upgrade` upgrades dsh and auto-restarts | Auto-recover after reboot (you re-run `dsh-web start` once) |
| No tmux? **Auto-installs it** (macOS/Linux package managers) | Auto-restart on **crash** (currently handles normal restarts only) |
| dsh web running in a plain terminal? **Auto-migrates into tmux** | Skill additions, AGENTS.md edits, etc. (these **already hot-reload**; not needed here) |
| Session not named `dsh-web`? **Auto-discovers** the hosting session | Auto-upgrade non-npm/pnpm dsh installs (only hints) |
| Port not 3080? **Auto-discovers** (incl. `--port 0` random ports) | — |
| All terminals closed — dsh web **keeps running**, restartable anytime | — |

**In one line**: for DSH changes that require a restart (install plugins, edit profile config, upgrade dsh), it safely auto-restarts and keeps dsh web resident; you just refresh after the brief disconnect.

## Commands

```bash
dsh-web restart    # ★ Core: unified command after installing/removing/updating plugins, editing profile config, or upgrading dsh
dsh-web start      # Start / auto-takeover (create session if none, migrate into tmux if unmanaged)
dsh-web stop       # Stop
dsh-web status     # Check session/port/PID/logs
dsh-web attach     # Enter tmux for troubleshooting
dsh-web autostart-on    # Enable autostart at login (default OFF, user opt-in; launchd/systemd)
dsh-web autostart-off   # Disable autostart
dsh-web autostart-status # Check autostart status
```

> **Users only need to remember `dsh-web restart`** — it covers all three scenarios: install/remove/update plugins, edit profile config, upgrade dsh (the agent auto-upgrades then restarts for the upgrade case). `reload`/`upgrade` are semantic aliases for agent-internal use; regular users don't need to distinguish them.

> **Autostart is optional and OFF by default** — the skill never enables autostart on its own. Run `dsh-web autostart-on` when you want dsh web to start in tmux after login.

> **Port notification policy**: after `start`/`restart`, the actual port is written to `~/.dsh/logs/last-port.txt`. If the port is the **default (3080), no notification** (everyone knows it); if **non-default** (occupied/random), a system notification shows the actual port — especially useful for unattended autostart.

## Conventions & Boundaries

| Item | Default | Override |
|---|---|---|
| tmux session name | `dsh-web` (auto-discovered if not found) | `DSH_WEB_SESSION` |
| Port | **auto-discovered** (explicit config > process `--port` > process listen port > node scan > default 3080) | `DSH_WEB_PORT` |
| Launch command | `dsh web` | `DSH_CMD` |

- **Port auto-discovery**: works even if you launched dsh web with `--port 8080` or `--port 0` (random) — the script parses the actual port from the process command line or listening socket.
- Closing all terminals is fine: tmux server is a daemon, detached sessions keep running, auto-restart still works.
- After reboot / `tmux kill-server`: **reopen dsh web however you like** — `dsh-web start` is easiest (creates tmux + starts + hosts in one step); plain `dsh web` also works, first `restart` auto-migrates into tmux (one extra migration, then fully automatic).
- If tmux can't be auto-installed, platform-specific manual commands are printed.

## How It Works (30-second version)

```bash
tmux run-shell -b "sleep 3; tmux send-keys -t dsh-web C-c; sleep 2; tmux send-keys -t dsh-web 'dsh web' Enter"
```

tmux server is an independent daemon — it doesn't depend on dsh web being alive. Even if the caller (agent) dies with dsh web, the restart still completes.

## Pitfalls We Hit

1. Synchronous restart = kills the host process = command interrupted → use `tmux run-shell -b`
2. `nohup ... &` background tasks get cleaned up when the caller's turn ends → use tmux server
3. GitHub tarball URL plugin installs leave pnpm lockfile missing `integrity` → use `github:owner/repo#ref`

## License

MIT

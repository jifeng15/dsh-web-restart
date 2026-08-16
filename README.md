# dsh-web-restart

> **True hot-loading for dsh web**: after installing plugins, editing config, or upgrading dsh itself, see the effect immediately — no more manually restarting from the command line.

[![dsh-plugin](https://img.shields.io/badge/dsh--plugin-yes-2ea44f?logo=deepseek)](https://github.com/topics/dsh-plugin)
[![dsh-skill](https://img.shields.io/badge/dsh--skill-yes-8e44ad?logo=deepseek)](https://github.com/topics/dsh-skill)
[![deepseek-harness](https://img.shields.io/badge/deepseek--harness-yes-4d6bfe)](https://github.com/topics/deepseek-harness)
![License](https://img.shields.io/badge/license-MIT-blue)
![Version](https://img.shields.io/badge/version-2.0.7-4d6bfe)

**English** | [简体中文](README.zh-CN.md)

## The problem it solves (what we actually hit)

While using **dsh web**, I found that DSH has three kinds of changes that **require a process restart to take effect** — installing/removing/updating plugins (bundle layers are composed at startup), editing profile config (`cordis.patch.yml`), and upgrading the dsh package itself.

Every time, I had to **leave the conversation, go to the command line, re-type `dsh web`**, and refresh the page to see the effect:

- ❌ **Not timely**: can't see plugin effects right after installing
- ❌ **Manual**: even when an agent installed the plugin in conversation, I still had to open a terminal
- ❌ **Fragile**: killing the process directly also kills the running agent session ("many rounds never finished")

**This skill syncs "hot reload" and "hot restart"** — things that DSH already hot-reloads (skills, AGENTS.md, settings) keep hot-reloading; plugin installs now **hot-apply without a restart**, and everything that genuinely must restart (config edits, dsh upgrade) is restarted **safely and automatically by the agent**. dsh web becomes truly hot-loadable: install a plugin in conversation, it's active immediately — **no more manual restarts**.

## Quick Start

Three ways to install, pick any:

**① Install via conversation (recommended)** — say this in a DSH conversation (**include the repo URL** so the agent knows where to install from):

> "**Install https://github.com/jifeng15/dsh-web-restart**"

The agent installs and loads the skill automatically (skills are hot-loaded — ready immediately, no restart needed).

**② One-line install** — in your own terminal:

```bash
npx -y skills add https://github.com/jifeng15/dsh-web-restart -g -y -a universal --copy
```

> `npx skills add` installs the **skill files** only (agents use the skill's
> script path — no command needed). To get the **`dsh-web` command** in your
> terminal, run once: `bash ~/.agents/skills/dsh-web-restart/install.sh --bin-only`
> (it installs to `~/bin/dsh-web` and auto-adds `~/bin` to your shell PATH).

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
3. **Automatically call** `dsh-web install` for plugins (hot install, **no restart**) or `dsh-web upgrade` for dsh itself — the agent calls the script directly, you never touch the command line
4. For hot installs, the plugin is active immediately; for upgrades, you just **refresh the page**

> For: users who manage plugins through DSH conversations. This is the skill's **primary scenario** — it's designed for agents.
>
> **First use note**: the very first time you hot-install, the agent automatically installs
> the hot-install component and restarts once (so it can load) — you just refresh that once.
> After that, every plugin install is **no-restart**.

### Scenario B: Manual command line — full control

If you prefer the terminal, install/remove plugins with the **hot** commands (no restart), and use `restart` for everything else:

```bash
dsh-web install <spec>   # Install plugin: hot install (no restart) if available, else safe restart
dsh-web remove <pkg>     # Remove plugin: hot uninstall if available, else safe restart (refuses CLI-managed — use `dsh plugin --profile web remove`)
dsh-web restart    # Fallback/other: safe restart after config edits, dsh upgrade, or when hot apply is unavailable
dsh-web session    # Report the resolved tmux session (auto-discovered)
dsh-web status     # Check status anytime
```

> **Hot first, safe restart as fallback**: `install/remove` try the bundled
> dsh-web-hot (no restart, PID unchanged). If hot apply is unavailable (plugin not
> loaded, module-level code update, or the change can't be hot-applied), they fall
> back to a safe restart automatically. `restart` remains the unified command for
> config edits, dsh upgrade, and migration.
>
> **Why the "extra step" is unavoidable**: the skill's automation trigger is the
> **agent** — when you install via conversation, the agent is present and auto-invokes
> it; but when you install from your own terminal, no agent is involved, so you must
> run it manually once. **This one-time step is worth it**: it migrates dsh web into
> tmux hosting, and after that everything (conversation-driven) is fully automatic.
>
> For: CLI users, script automation, and agent-internal calls. All commands **automatically** handle tmux hosting, port discovery, and session discovery — no preparation needed.

## At a Glance: What It Can / Can't Do

| ✅ **Can** | ❌ **Can't** |
|---|---|
| **Hot install/uninstall** plugins via bundled dsh-web-hot — **no restart** (falls back to safe restart if unavailable) | Agent **continuing seamlessly** after restart — restart briefly disconnects, you refresh (structural limit) |
| **Auto-restart** dsh web after plugin changes, config edits, or dsh upgrade — **no manual commands** (conversation) | Hot-apply **module code updates** (Node require cache — must restart) |
| `reload` takes effect after editing profile config (`cordis.patch.yml`) | Auto-recover after reboot (you re-run `dsh-web start` once) |
| No tmux? **Auto-installs it** (macOS/Linux package managers) | Auto-upgrade non-npm/pnpm dsh installs (only hints) |
| dsh web running in a plain terminal? **Auto-migrates into tmux** (run `dsh-web start`/`restart`, or enable the watchdog for fully automatic takeover) | Skill additions, AGENTS.md edits, etc. (these **already hot-reload**; not needed here) |
| Session not named `dsh-web`? **Auto-discovers** the hosting session | Crash auto-restart is a separate opt-in (run-loop) |
| Port not 3080? **Auto-discovers** (incl. `--port 0` random ports) | — |
| All terminals closed — dsh web **keeps running**, restartable anytime | — |

**In one line**: install/uninstall plugins **without restarting** (hot), and for everything that genuinely must restart (config edits, dsh upgrade, migration), it restarts safely and keeps dsh web resident — you just refresh after the brief disconnect.

## Commands

```bash
dsh-web install <spec>   # ★ Install plugin: hot install (no restart) if available, else safe restart
dsh-web remove <pkg>     # ★ Remove plugin: hot uninstall if available, else safe restart (refuses CLI-managed — use `dsh plugin --profile web remove`)
dsh-web restart    # ★ Fallback/other: unified safe restart after plugin changes, config edits, or dsh upgrade
dsh-web start      # Start / auto-takeover (create session if none, migrate into tmux if unmanaged)
dsh-web stop       # Stop
dsh-web status     # Check session/port/PID/logs
dsh-web attach     # Enter tmux for troubleshooting
dsh-web autostart-on    # Enable autostart at login (default OFF, user opt-in; launchd/systemd)
dsh-web autostart-off   # Disable autostart
dsh-web autostart-status # Check autostart status
dsh-web watchdog-on     # Enable launchd watchdog: every 30s, auto-migrate any unmanaged dsh web into tmux (default OFF)
dsh-web watchdog-off    # Disable watchdog
dsh-web watchdog-status # Check watchdog status
dsh-web repair       # Fix config: same-file duplicate ids, ghost bundles, cross-source duplicates (auto-backup first)
dsh-web health-check # Check port + config tree — is it a process or a config problem?
dsh-web preflight    # Boot self-check (auto-run by start/restart): clear cross-source duplicates
```

> **Hot install first, safe restart as fallback**: `dsh-web install/remove` try the
> bundled hot-plugin (dsh-web-hot) first — installing/uninstalling plugins **without
> a restart**. If hot apply is unavailable (plugin not loaded, or the change can't be
> hot-applied), it falls back to a safe restart automatically. `dsh-web restart` remains
> the unified command for everything else (config edits, dsh upgrade, migration).
>
> **One owner per plugin (single-source)**: a plugin is mounted from exactly one
> source — either `dsh plugin --profile web add|remove` (the `dsh.profile.bundles`
> list) or hot install (the `cordis.patch.yml` patch layer), never both. If the same
> plugin ends up in both (e.g. an external `dsh plugin add` adopts a previously
> hot-installed one), `preflight` (auto-run by `start`/`restart`) and `repair`
> detect it and drop the patch-layer rows automatically — the next boot can't crash
> with `duplicate loader entry id`. On the remove side, `dsh-web remove` refuses
> CLI-managed plugins (it would leave a ghost bundle) and points to `dsh plugin remove`.

> **Autostart is optional and OFF by default** — the skill never enables autostart on its own. Run `dsh-web autostart-on` when you want dsh web to start in tmux after login.

> **Port notification policy**: after `start`/`restart`, the actual port is written to `~/.dsh/logs/last-port.txt`. If the port is the **default (3080), no notification** (everyone knows it); if **non-default** (occupied/random), a system notification shows the actual port — especially useful for unattended autostart.

### Watchdog: fully automatic takeover (optional, default OFF)

`dsh-web watchdog-on` installs a launchd LaunchAgent that checks every 30 s:
if dsh web is listening but **not** hosted in tmux (e.g. you started it in a
plain terminal), it automatically migrates it into tmux — so after that,
closing the terminal never kills dsh web, **no matter how you started it**.
The watchdog only migrates a *running* web; it never starts a stopped one.
Disable with `dsh-web watchdog-off`. macOS only (Linux systemd timer: future).

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

## Architecture & Data Flow (technical)

### Components

| Component | Role |
|---|---|
| `scripts/dsh-web.sh` | Main CLI (start/restart/install/remove/upgrade/status/session/autostart-*) |
| `hot-plugin/` (dsh-web-hot) | Host plugin: hot install/uninstall via `include.update` (no restart) |
| `scripts/run-loop.sh` | Crash auto-restart loop (3-strike circuit breaker) |
| `scripts/install-tmux.sh` | Cross-platform tmux auto-install |
| `install.sh` | One-shot install (skill + CLI + hot-plugin + tmux) |

### Hot install (no restart) data flow

```
dsh-web.sh install <spec>
  → POST /dsh-web-hot/install {spec}
    → pnpm add <spec> (profile dir, official registry)
    → read bundle's dsh.bundle.patch → patch rows
    → write cordis.patch.yml (user patch layer, persistent)
    → include.update (hot apply, PID unchanged)
    → record dsh-web-hot.state.json
  → {"ok": true}
```

### Safe restart data flow

```
dsh-web.sh restart
  → resolve_session (discover actual session, e.g. "0")
  → tmux run-shell -b "sleep 3; C-c; sleep 2; 'dsh web'"
  → tmux server executes independently (completes even if agent dies)
  → 5-8s later dsh web restarts; user refreshes
```

### Single-source principle (why plugins must not double-mount)

`dsh plugin --profile web add` (the bundle list) and hot install (the user patch
layer) both feed include entries into the **same loader**, whose entry ids must be
unique. If the same plugin ends up in both sources, the next boot dies with
`duplicate loader entry id`. This project enforces **one owner per plugin**:

- hot install refuses bundles already in `dsh.profile.bundles` (install-time guard);
- `preflight` (auto-run by `start`/`restart`) and `repair` detect cross-source
  duplicates — entry ids declared by bundles ∩ patch-layer rows — and drop the
  patch-layer rows (bundles side is authoritative), syncing `dsh-web-hot.state.json`;
- the `dsh-web-hot` plugin self-heals at startup for running-process drift (HMR
  reloads, manual state edits), hot-unmounting rows via `include.update`.

So an external `dsh plugin add` that adopts a previously hot-installed plugin is
auto-reconciled before the next boot — no manual cleanup needed.

### Environment dependencies

| Dep | Use | If missing |
|---|---|---|
| tmux | hosting + independent restart | auto-installed |
| pnpm | plugin install (via dsh-web-hot) | hot install degrades to safe restart |
| dsh CLI | install.sh hot-plugin install | hot-plugin skipped |
| curl/lsof/ps/pgrep | probing | — |

## Pitfalls We Hit

1. Synchronous restart = kills the host process = command interrupted → use `tmux run-shell -b`
2. `nohup ... &` background tasks get cleaned up when the caller's turn ends → use tmux server
3. GitHub tarball URL plugin installs leave pnpm lockfile missing `integrity` → use `github:owner/repo#ref`

## License

MIT

## Changelog

### v2.0.7 (coexists with dsh-market on pnpm-workspace.yaml)

- 🔀 `ensureWorkspaceAllowed` now **merges** into dsh-market's `allowBuilds`
  object style (name → boolean, incl. its "set this to true or false" template)
  instead of overwriting it with our legacy list format. Both tools can now
  write the same file without clobbering each other.

### v2.0.6 (install.sh auto PATH)

- 🔧 `install.sh` installs the `dsh-web` command and **auto-adds its bin dir to
  your shell PATH** (previously the command was installed but not found).

### v2.0.5 (launchd watchdog — fully automatic takeover)

- 🐕 **`dsh-web watchdog-on`**: a launchd LaunchAgent checks every 30 s — if dsh
  web is listening but **not** hosted in tmux (e.g. you started it in a plain
  terminal), it auto-migrates it into tmux. So no matter how you start dsh web,
  closing the terminal no longer kills it. Opt-in (default OFF), managed with
  `watchdog-status` / `watchdog-off`. The watchdog only migrates a *running* web —
  it never starts a stopped one.

### v2.0.4 (migration race fix)

- 🔧 `start` auto-takeover (plain-terminal dsh web → tmux) now creates an **empty**
  tmux session first and launches dsh web only after the old process is stopped and
  the port is free. Previously the new instance started immediately and fought the
  old one for the port (`EADDRINUSE`), burning the run-loop's 3-strike breaker.
- ✅ Verified end-to-end with a dummy process + harmless launch command: empty
  session → old process killed → port released → dsh web starts inside tmux.

### v2.0.3 (remove single-source guard)

- 🔒 `dsh-web remove <pkg>` now **refuses plugins managed by `dsh plugin`** (present
  in `dsh.profile.bundles`) and points you to `dsh plugin --profile web remove <pkg>`.
  The old fallback removed the dependency but left the bundle entry behind (ghost
  bundle). One owner per plugin, now enforced on the remove path too.

### v2.0.2 (cross-source single-source hardening)

- 🛡️ **Cross-source duplicate detection & self-heal** — the `duplicate loader
  entry id` crash (same plugin mounted via both `dsh.profile.bundles` and the
  hot-install patch layer) is now prevented and auto-repaired:
  - `dsh-web repair` runs a new cross-source check first: entry ids declared by
    bundles ∩ patch-layer rows → drops the patch-layer duplicates (bundles side
    is authoritative) and syncs `dsh-web-hot.state.json`.
  - `dsh-web preflight` (boot self-check) — `start`/`restart` run it before
    launching, so an external takeover (e.g. `dsh plugin add` adopting a
    hot-installed plugin) can never crash the next boot.
  - `dsh-web-hot` startup self-heal — the host plugin drops patch rows for any
    hot-managed bundle that `dsh.profile.bundles` has since adopted (covers
    running-process drift / HMR reloads).
- 🩹 v2.0.1's `repair` / `health-check` / auto config backup are now documented
  here too (they shipped in v2.0.1 but the README wasn't synced).

### v2.0.1 (repair & health-check)

- 🛠️ `dsh-web repair`: dedup duplicate ids, remove ghost bundles, resync
  `dsh-web-hot.state.json`; auto-backup before any config change (keeps last 10).
- 🩺 `dsh-web health-check`: port readiness + config tree (`--dump-config`) —
  tells you whether it's a process or a config problem.
- 🔒 Hot install rejects bundles already in `dsh.profile.bundles` (prevents the
  duplicate loader entry id crash from the hot-install side).

### v2.0.0 (hot install, no restart)

- 🎉 **Hot install/uninstall** — installing/removing plugins no longer restarts.
  Bundled `dsh-web-hot` host plugin hot-applies patch rows via `include.update`
  at runtime; **the PID never changes**.
- ✨ New commands: `dsh-web install <spec>` (hot first, fallback to safe restart),
  `dsh-web remove <pkg>` (hot first, fallback to safe restart).
- 🛡️ `dsh-web session`: report the resolved tmux session (auto-discovered, never
  assumes `dsh-web`).
- 📦 Module-level code updates still require a restart (Node require cache) —
  structural limit, falls back automatically.

### v1.0.0 (safe restart)

- First release: tmux hosting + tmux-server independent delayed restart, covering
  plugin changes, config edits, and dsh upgrades.
- Crash auto-restart with a 3-strike circuit breaker; port/session auto-discovery;
  bilingual README.

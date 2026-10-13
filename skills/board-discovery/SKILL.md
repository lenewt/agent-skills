---
name: board-discovery
description: Discover everything useful about an embedded Linux target board or device (Yocto, Buildroot, Debian, Android shell) over serial console, ssh, adb or locally - identity, partitions and free space, init system and services, running apps and how they are started, listening ports, network stack, display, hardware buses, logs, databases, update mechanism - as a read-only snapshot per board, a deep-dive per application, and a drift diff between snapshots. Then turn the findings into a board-specific skill (like a "<product>-board" skill) with its references. Use when meeting a new board, when a board skill may be stale, before and after a deploy or test to check what changed, or when asked to write a skill or tooling for a device.
---

# board-discovery: inventory a target board, then write its skill

Two tools in `bin/` next to this file (Claude Code: `~/.claude/skills/board-discovery/bin/`), Python 3 on the host,
`pyserial` for serial targets. Nothing is installed or written on the board.

| Tool | Does |
|---|---|
| `devsh -T TARGET CMD...` | runs shell commands on the target, prints `### CMD [rc=N]` + output, redacts `key=secret` values |
| `discover -T TARGET` | runs `lib/probes.txt` (~30 read-only probes, BusyBox safe) and saves a snapshot for the board |
| `discover --app PATTERN` | deep-dive on matching processes: cmdline, parents/children, systemd unit + drop-ins, environment (redacted), open files, own libraries, sockets |
| `discover --repo [PATH]` | links the workspace at PATH (default `.`: the repo, its submodules and nested repos) with the board: each product file on the board is matched to a local file as `identical` (sha256), `same build-id` (ELF, survives stripping), `same runtime only` (AppImage-like payload differs) or `differs`, plus build targets that declare it, versions in board paths traced to a tag or commit (and how far HEAD is ahead), repo files that reference board locations (deploy scripts, constants) and board units against the repo's unit files |
| `discover --diff [OLD [NEW]]` | drift between snapshots of one board (volatile probes skipped, pids/sizes/`ls` dates ignored); `OLD` may be `<board id>/<stamp>` to compare across ids |
| `discover --list` | boards and snapshots on file (`$BOARD_DISCOVERY_HOME`, default `~/.local/state/board-discovery`) |

TARGET (or `$DEVSH_TARGET`): `serial[:/dev/serial/by-id/<adapter>][@115200]` (no port: the first ttyUSB/ttyACM that
answers; `ttyUSBn` numbers move with replugs, the `/dev/serial/by-id/` path does not),
`ssh:[user@]host[:port]`, `adb[:serial]`, `local`. The board id is the hostname plus a hash of a hardware identity
(device-tree serial, else the eMMC CID), so it survives a reflash; boards without one fall back to `/etc/machine-id`,
which a reflash regenerates (then the reflashed board shows up as a new id: diff across ids with `<id>/<stamp>`). User `$DEVSH_USER` (root), serial password `$DEVSH_PASSWORD`.
`--noise REGEX` drops console spam lines (services that log to the tty). `discover` remembers the last target per
board, so `--app`/`--diff` with `--name <board id>` need no `-T`.

## Workflow

1. **Reach a shell.** Ask the user how the board is connected if unknown. Try `devsh -T serial --check`
   (bootstrap, works without network) or `devsh -T ssh:<ip> --check`. On "no shell", read the "last console output"
   line: nothing at all means a wrong port, no power or a board still booting (a fresh flash can take minutes, so retry);
   a login or password prompt that did not take means a login problem, not cabling. `ls -l /dev/serial/by-id/` names the adapter. On a serial console that prints service logs,
   look at a few raw lines and pass `--noise '<timestamp prefix regex>'`. Prefer ssh once the network is up: it is
   faster (~15 s per snapshot against ~25 s) and free of console noise.
2. **Snapshot.** `discover -T <target>`. Read the printed headline (OS, init, network managers, near-full disks,
   non-standard executables, failed units), then read `snapshot.md` in full. Probes that return rc=1 usually just
   had a missing optional tool; rc=-1 is a timeout.
3. **Deep-dive** every product process (the "non-standard executables", custom units, children of a launcher):
   `discover --name <id> --app <exe name>`. Follow `reference/method.md` to go from processes to units, config,
   logs, databases, IPC, update path and network setup, with targeted read-only `devsh` commands.
4. **Link the workspace** when a project repo is open: `discover --name <id> --repo <repo root>` (~20 s over ssh;
   over serial console noise can spoil a few ELF dumps, so fewer build-id matches). Read `repo-map-*.md`: it says
   which local build or package each board file came from, which source repo builds it, whether the board runs
   the checkout's version, and which repo files (deploy scripts, launcher constants) own the board paths.
5. **Interview** the user only for what the board cannot tell (method.md, "Ask the user"): purpose of each
   component, physical side effects, safe restart, build and deploy from the host project, which facts are
   per-unit versus per-product.
6. **Generate the board skill** from `templates/board-skill/` (method.md, "Generate"): `SKILL.md` and
   `reference/` files. It calls `devsh` through a one-line shell function with the target and noise; do not
   copy or wrap the transport in a project-named script. Put it where the user keeps
   project skills, not in this repo. Each fact carries "verified on <board id>, <date>".
7. **Re-check later.** Start every session that uses an older board skill with its freshness check (one cheap
   identity command, see Generate): a reflash can wipe the product, test trees and drop-ins. Before and after a deploy or test:
   `discover -T … && discover --diff --name <id>`, and `--repo` to see whether a deploy landed (the new build's
   files turn `identical`/`same build-id`). Fold confirmed drift into the board skill, and report the rest
   (leftover test trees, changed unit drop-ins, full disks) to the user.

## Rules

- **Read-only.** No writes, restarts, mounts, package installs or DB opens in write mode during discovery. Ask
  before anything that changes the board, even "harmless" ones (`nmcli radio wifi on`, `systemctl restart`).
- **Secrets.** Output is redacted for `password|secret|token|psk|api key|private key` = values, and the probes list
  network profile names, not their contents. Never `cat` shadow files, `*.nmconnection`, wpa configs, TLS keys or
  DB rows into the transcript; never copy redacted values into a generated skill.
- **Live devices.** A board may drive actuators or other physical hardware. Discovery does not tap the UI,
  send on CAN/serial buses or call device IPC. Record such interfaces in the skill; do not exercise them.
- Snapshots stay on the host under `$BOARD_DISCOVERY_HOME`, outside any git repo. They contain hostnames, IPs,
  serial numbers and machine ids: do not commit or publish them.
- Add a probe: one line in `lib/probes.txt` (`name|timeout|diff mode|command`), POSIX sh, under ~1 KB, no writes.

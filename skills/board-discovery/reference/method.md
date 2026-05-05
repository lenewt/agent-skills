# Discovery method: from a snapshot to a board skill

## Deep-dive checklist (read-only `devsh` commands)

Work from what runs to where it comes from. For each product component, find:

| Question | Where to look |
|---|---|
| What starts it, with which arguments | `discover --app`: parents, `unit` (base unit **and** drop-ins in `/etc/systemd/system/<unit>.d/`), `systemctl show -p ExecStart,Restart,BindsTo,After`; SysV: `/etc/init.d`, `/etc/inittab`; a launcher process: its children and its own config |
| Which version is live, and how it is chosen | versioned dirs (`ls -l <app root>`), symlinks (`ls -l`, `readlink -f`), launcher arguments, version files (`strings <exe> \| grep -i version` only if needed) |
| Its files | exe dir, `cwd`, the "libraries" outside system dirs, open files (configs, DBs, logs, ttys, sockets), `ls -la` of each dir found |
| Configuration | open or nearby `*.ini/*.conf/*.json/*.xml`, the unit `Environment=`/`EnvironmentFile=`, flags files read at start; list them, read non-secret ones |
| Data | `databases` probe + open files; for SQLite: `sqlite3 -readonly <db> .tables` (schema only, no rows unless the user asks); which file is live vs factory/backup; WAL present (do not copy without stopping the writer) |
| Logs | open log files, `logs` probe (size + date shows which are active), `journalctl -u <unit> -n 50 --no-pager`, `StandardOutput=tty` (logs on the serial console) |
| IPC and ports | `listening` probe, open sockets/FIFOs, D-Bus policy files (`/etc/dbus-1/system.d/`), named pipes next to the exe |
| Display and input | `display` probe: X or Wayland, DISPLAY, resolution and rotation, which window/process is on top, touch device |
| Network setup | the manager in `net-managers`, profile names, udev renames (`net-naming`), whether the product rewrites the network config at start (profiles with recent mtimes, the app opening NetworkManager D-Bus) |
| Remote access | `remote-access` + `consoles`: ssh policy, root login, serial console device and speed (from `/proc/cmdline`), getty |
| Update and deploy path | `update` probe, updater units and scripts (read them), removable-media automount, partitions: what survives an update (separate data partition?), free space where a deploy would land |
| Restart and recovery | unit `Restart=`, watchdog, which units are `BindsTo`/`Requires`, how long a restart takes (ask before trying) |
| Leftovers and drift | non-standard dirs in `apps-dirs`, drop-ins that override packaged units, backup copies of DBs, test trees: compare with what the user expects |

Stop digging a component once you can answer: how to stop/start it, where its binary/config/data/logs are, how to
replace it with a new build, and how to see that it is healthy.

## Workspace link (`discover --repo`)

Use the repo map to answer, per component: which repo and build target produce it, which local output or package
matches the deployed file, which version/commit it corresponds to, and which repo files encode the board layout
(deploy `.pri`/scripts, launcher paths, package builders). Treat its verdicts as evidence levels:
`identical` > `same build-id` (same link output, stripped or not) > a version string traced to a commit > a name
match only. `same runtime only` and `differs` say nothing about the content. No match at all usually means the file
came from elsewhere (a downloaded package, another workspace, a manual copy): ask.

## Ask the user (batch into one question round)

- What each product component is for, in one line; which names map to which product terms.
- Physical side effects: which UI actions, buses (CAN, RS-232/485, GPIO) or commands move or switch hardware.
  These become the skill's Safety section.
- How builds are produced on the host (project repo, toolchain, cross-compile env) and how they reach the board
  today (scp, package, updater, removable media).
- Which facts hold for every unit of this product, and which are per unit (IP, serial, installed options).
- Anything to leave alone (customer data, calibration, production DBs).

## Generate

Copy `templates/board-skill/` to the user's project skills directory as `<product>-board/` and fill it:

- **`SKILL.md`** (target: under ~100 lines). It holds the frontmatter description with trigger words (board name,
  SoC, distro, product names, "deploy", "logs"), how to connect (the `devsh` function, console device, speed, login, noise),
  how to enable the network, a component map table (piece, path, started by), the data and log paths, the restart
  commands and the Safety section. With a repo map, the component map gets a "built from" column (repo, target,
  local output path) and the build-deploy reference cites the repo files that own the board paths. Load-on-demand details go in `reference/`.
- **Transport**: a `D() { …/devsh -T "${T:-<target>}" --noise '<regex>' "$@"; }` line at the top of each command
  block (a variable would split the regex). No project-named copy or wrapper of `devsh`: the transport has one
  implementation, here. Board quirks the transport must handle belong in `devsh` as generic options.
- **`reference/layout.md`**: hardware/OS, partitions, units, processes, filesystem map, databases, with
  "verified on <board id>, <date>" at the top. **`reference/networking.md`**, **`reference/build-deploy.md`**: only
  when discovery or the user gave real content.
- Facts that drift (versions, IPs, test trees, free space): write **how to find them** (a command), not only the
  value seen once. Stable facts (paths, unit names, partition roles): write the value.
- Mark anything inferred and not verified as such. Never include redacted values, keys or customer data.
- Add a "Drift check" line: `discover -T <target> && discover --diff --name <board id>` from board-discovery.
- Reuse what the project already has: a skill that exists already (update it rather than writing a second one),
  existing scripts in the project repo for deploy or flashing (reference them, do not copy them).

When updating an existing board skill, diff the new snapshot against what the skill states, fix what changed, and
keep the verified date per section.

---
name: instrument-e2e
description: Equip a product under test with hook, debug and puppet points for E2E tests (test-only log lines, readiness signals, and a gated Unix-socket control channel that injects sensor values, hardware events or failures), planned by a cheap, separate Copilot CLI scout that reads the source read-only and checks existing logs, config and actions first through blackbox-e2e's `e2e` verbs. Use when discover-e2e (or a blackbox-e2e/whitebox-e2e run) reports a step it cannot observe or stimulate, when a profile sleeps instead of waiting for readiness, or up front to instrument a new product. Writes a plan (points, snippets, profile wiring); the dev session applies it.
---

# instrument-e2e: make the product observable and drivable for E2E

Paths in this file (`bin/…`, `templates/…`, `references/…`, `../<skill>/…`) are relative to this skill's folder, wherever it is installed.

A black-box tester sees the screen, the declared log patterns and the declared actions, nothing more. Some steps
need more: an event the screen hides, a moment the app is ready, an input no fixture reaches (a sensor reading, a
switch, a network failure). `bin/instrument-e2e` sends a **scout** (Copilot CLI, claude-haiku-5.5 by default,
locked down like the discover-e2e scout) to find, for each such item, an existing means or the smallest point to
add. It returns a **plan**. It changes nothing; the dev session applies the plan in the product repo.

## The three points

| Kind | Does | Test side |
|---|---|---|
| debug | logs `E2E <event> key=value…` when `E2E_TRACE=1` | a log pattern in the scenario |
| hook | logs `E2E ready` (optional `E2E idle`), or resets state on start | `wait_for LOGFILE 'E2E ready' N` in the profile |
| puppet | a handler on a test-only Unix socket at `$E2E_PUPPET`: `point args` -> `ok[ data]` / `err reason` | `-- @action` blocks through `puppet_action` |

All three are built only with the `E2E_PUPPET` build flag and active only when their env variable is set. They
stimulate or report facts; they never judge. The full contract is `references/protocol.md`.

## Run

```bash
bin/instrument-e2e --profile NAME|FILE [--from DISCOVER_DRAFT_DIR] [--goal "…"] [--change RANGE] \
  [--ticket FILE] [--source DIR] [--host U@H] [--set KEY=VALUE]... [--model claude-sonnet-5.5] [--budget USD] [--out DIR]
```

- `--from`: a discover-e2e draft dir. Its steps, open questions and the stimuli its fixtures lack become the items
  to make testable; `--profile`, `--change` and `--goal` default to the draft's.
- `--goal`: one line, what must become testable (default: the first commit subject of `--change`).
- `--change`, `--ticket`, `--source`, `--host`, `--set`: as for discover-e2e. The scout starts the app with the same
  profile options the tester gets.
- Limits: `E2E_SCOUT_BUDGET` USD 0.5, 200 `e2e` calls, 40 screenshots.

**Cost rule: the author does not explore.** If the plan misses an item, rerun the scout with a sharper `--goal` or
`--ticket`. Do not grep the code or drive the UI yourself to find insertion points.

## Read the output (only these files)

The wrapper prints the scout cost, the points per kind, the risk and open-question counts, and the paths.

| File | Read it? |
|---|---|
| `plan.md` | yes: the setup (library load), the points table, then one section per point (file, anchor, language, gating, snippet) and the risks |
| `open-questions.md` | yes: what the scout could not settle (decide or ask the user) |
| `profile-snippet.sh` | yes, when wiring the profile |
| `map-additions.md` | yes: existing logs, rows or actions the scout verified (no code needed for those) |
| `points.json` | for an implementer agent: `{setup, points}` as JSON |
| `scout/` | no (raw scout run) |

## Apply

Delegate to an implementer agent in the product repo, with `plan.md`, `points.json`, `references/protocol.md` and the
reference for the product's stack. It copies the snippet library from `snippets/`, inserts each point at its
anchor, adds the `E2E_PUPPET` build option and builds the test variant (`-DE2E_PUPPET=ON` for CMake). The release
build stays without the flag; add the release check from `references/protocol.md` to its pipeline.

## Wire the profile

Merge `profile-snippet.sh` into the project profile: `PUPPET_HOST`/`PUPPET_SOCK`, `E2E_PUPPET=… E2E_TRACE=1` on
start, the log file in `LOG_FILES`, `wait_for … 'E2E ready'` instead of a sleep, and

```bash
profile_action() { puppet_action "$@"; }
```

`puppet_send HOST SOCK LINE` and `puppet_action NAME FILE` come from blackbox-e2e's `lib/stack.sh`. Each line of an
`@action` block is one puppet request; a reply other than `ok…` fails the action.

## Verify

Accept the verified map additions (`bin/instrument-e2e --accept-map PLAN_DIR [--only 1,3]`), then rerun
`../discover-e2e` on the instrumented build: its scout can now `e2e try-action 'sensor 42'` and `e2e grep 'E2E '`.
Run the resulting draft with blackbox-e2e. An unknown point shows up as `err unknown point NAME` in the action's
failure; `try-action 'help'` lists the points the build has (it is not recorded as a stimulus).

## Conventions

`references/protocol.md` is the contract every point implements (gating, transport, line format, hooks). Per stack:

| Stack | Reference | Snippet |
|---|---|---|
| Qt / C++ | `references/qt.md` | `snippets/qt/` (`E2ePuppet.{h,cpp}`, CMake option) |
| Node | `references/node.md` | `snippets/node/e2e-puppet.js` |
| Python (Tk, Qt) | `references/python.md` | `snippets/python/e2e_puppet.py` |
| no source: shell, systemd | `references/shell-systemd.md` | drop-ins, wrappers, fake devices |

`tests/puppet-proto.sh` checks the Node and Python snippets against the protocol (and the Qt one when Qt is installed).

## Files

`bin/instrument-e2e` wrapper · `templates/brief.md` scout brief · `templates/draft.schema.json` ·
`templates/check.jq` (the runner's validity check for the plan) · `references/` contract and per-stack guides ·
`snippets/` libraries to copy · `tests/puppet-proto.sh`. Scout mode lives in blackbox-e2e (`e2e-run.sh --scout DIR`);
the map template is discover-e2e's.

---
name: blackbox-e2e
description: Black-box end-to-end test of any GUI application (local X11 under Xvfb, or a remote X11 device over ssh), run by a separate locked-down tester (`claude -p` on Haiku, or Copilot CLI on Claude Haiku 5.5) that cannot read source code. Only an `e2e` command is available to it (start/stop, screenshots, taps, declared log patterns, declared SQL fixtures). Use for E2E, smoke or acceptance tests of a change, especially when the tester must not see the code. Reports PASS/FAIL per step with the total cost. A project plugs in its app with a profile (a small bash file).
---

# blackbox-e2e: black-box E2E through a separate, locked-down tester

Paths in this file (`bin/…`, `templates/…`, `../<skill>/…`) are relative to this skill's folder, wherever it is installed.

You (the dev session) **author** a behavioural scenario. `bin/e2e-run.sh` **runs** it in a fresh, headless tester
whose only tools are `e2e <verb>` (a shim on its PATH) and a file viewer limited to its own screenshots. The tester
never sees the code, the paths or the build. A **profile** adapts the target app: how to start and stop it, where
its logs are, and how to apply fixtures. Requires the `uidrive` CLI of the `ui-drive` skill (found next to this skill in the repo, or set `$UIDRIVE`), plus
`jq`, `perl`, ImageMagick `convert`, `flock` and `Xvfb`/`xdotool` for local apps.

## 1. Pick or write a profile

| Profile | For | Key options |
|---|---|---|
| `x11-command` (built in) | any local X11 app under its own Xvfb | `--set cmd="…"` (required), `desc=`, `size=WxH`, `display=:97`, `cwd=`, `log="…"`, `db=` |
| `ssh-x11-systemd` (built in) | a remote X11 device whose app is a systemd unit | `--host U@H` (required), `--set unit=…` (required), `desc=`, `log=`, `db=`, `boot=30`, `real=1` |
| project profile | anything else, or an app with several processes | a `.sh` file in a dir listed in `E2E_PROFILE_PATH` |

Profile contract: the top level holds only assignments and function definitions. It is sourced by the runner and by
every `e2e` call. `lib/stack.sh` provides `spawn`, `kill_group`, `kill_all_groups`, `groups_status`, `group_alive`,
`wait_for`, `xvfb_start`, `port_busy`, `rsh`, `ui_geom`, `sqlite_backup/restore/apply`, `puppet_send`,
`puppet_action`, `die` (a verb fails) and `blocked` (setup cannot run, exit 3).

```bash
PRODUCT_DESC="…"   REAL_DEVICE=0|1            # one line for the tester; 1 adds "taps have physical effects"
UI_TARGET=local|U@H   UI_DISPLAY=:99   SCREEN_W=…   SCREEN_H=…    # or call ui_geom in profile_setup
LOG_HOST=local|U@H   LOG_FILES=(…)            # `e2e log` only reads the lines written during the run
LINT_PATTERNS=(…)   STATE_DIR=…   PROFILE_VARS=(…)   # product names to refuse; ledger/lock dir; vars setup computes
profile_setup        # runner: check the build, compute PROFILE_VARS; blocked "…" when it cannot run
profile_start / profile_stop / profile_status
profile_fixture FILE pre|live ; profile_db_backup ; profile_db_restore    # optional: SQL fixtures
profile_action NAME FILE   # optional: run an @action block (its body is the profile's own mini-language)
profile_teardown     # optional (default: profile_stop, then the DB restore when fixtures ran)
```

Copy `profiles/x11-command.sh` as a starting point. `--set key=value` reaches the profile as `$E2E_SET_key`, and
`--host` as `$E2E_HOST`.

Products with puppet points (a test-only Unix socket, see `../instrument-e2e/SKILL.md`) need no action code of their
own: set `PUPPET_HOST=local|U@H` and `PUPPET_SOCK=…` and define `profile_action() { puppet_action "$@"; }`. Each line
of an `@action` block is then one request; a reply other than `ok…` fails the action. `puppet_send HOST SOCK LINE`
sends one line and prints the reply (client: `socat`, `nc -U` or `python3` on HOST). When a step cannot be observed
or stimulated at all, the `instrument-e2e` skill plans the points to add.

## 2. Look first, then write the scenario (behaviour only)

Prefer the **`discover-e2e`** skill: a cheap scout explores and drafts the scenario and its fixtures, so your own
session does not pay for screenshots and log greps. The manual way below remains for small edits.

Never write steps from memory, the DB or translation files: labels, screens and auto-advancing flows are only known
after you see them. Explore first, which costs nothing (no tester):

```bash
bin/e2e-run.sh draft.md --fixtures f.sql --explore [--explore-fixture NAME]...
```

It starts the stack with the `setup` fixture, saves `shots/start.png`, then applies each `--explore-fixture` in
order and saves `shots/after-NAME.png`. Read the screenshots, then write the steps against them.

```
# Scenario: <title>
Target: <profile name>
## Steps
1. <action in UI terms> -- PASS if <what is visible on screen, or a named log pattern matches>
## Log patterns
- <name>: <extended regex>
## Safety
<free text>; one `rect: x1 y1 x2 y2` per forbidden screen area (taps inside are refused)
```

- **No source**: no file paths, code identifiers or code fences. `bin/e2e-lint.sh` refuses them (plus the profile's
  `LINT_PATTERNS`). Describe what a person at the screen sees; put protocol evidence in log patterns. Words such as
  "return", "import" or "class" are fine in prose: the lint refuses only code shapes (`return x;`, `void f(`,
  `class X {`). `tests/lint-cases.sh` checks both.
- Name controls by their look and position ("the rightmost of the three layout icons"). If a step is *meant* to be
  refused, say so explicitly, or a careful model will skip it to obey Safety.
- 3 to 15 steps, each with one observable criterion; at most 12000 bytes. Example: `templates/scenario.example.md`.
- Fixtures: a separate SQL file with `-- @fixture <name>` blocks. `setup` is applied before start; the others are
  offered to the tester by name only. The DB is backed up first and restored at teardown.
- Actions: `-- @action <name>` blocks in the same file, for stimuli that are not SQL (a simulated sensor value, a
  restart, one request). The body is passed to the profile's `profile_action`, whose verbs the profile documents. The
  tester applies them with the same `e2e fixture NAME`. Never fake an action with a SQL sentinel.
- **Stimulate, never judge.** Fixtures and actions change the input. They must not check the product and log a
  verdict that the tester only relays: that is a self-graded test. `e2e-lint.sh` refuses log patterns that match
  PASS/FAIL. Assert the protocol in unit tests; in E2E, judge what the screen and the product's own logs show.

## 3. Run

```bash
bin/e2e-run.sh <scenario.md> [--profile NAME|FILE] [--host U@H] [--set k=v]... \
    [--fixtures f.sql] [--engine claude|copilot] [--model M] [--budget USD] [--out DIR] [--source DIR]
# e.g. the demo:
bin/e2e-run.sh templates/scenario.example.md \
    --set cmd="xcalc -geometry 400x560+0+0" --set size=400x560 --set desc="a desktop calculator (xcalc)"
```

Run it in the foreground (a run usually takes 20–90 s). Do not watch the tester. Exit codes: 0 = PASS, 1 = FAIL
or BLOCKED, 2 = usage, 3 = BLOCKED before the tester started (busy lock, no build, unreachable device).
Run dirs go to `$CLAUDE_SCRATCHPAD` or `$TMPDIR`, and must not be inside a git repository (the runner refuses).

The engine is `--engine`, else `$E2E_ENGINE`, else the calling session's tool: `copilot` inside a Copilot session
(`COPILOT_CLI` or `COPILOT_AGENT_SESSION_ID` set, `CLAUDECODE` unset), `claude` otherwise.

| | `claude` | `copilot` |
|---|---|---|
| CLI and model | `claude -p --restricted`, `haiku` | Copilot CLI `copilot -p`, `claude-haiku-5.5` |
| Billed to | the Claude Code login | Copilot AI credits (1 credit = $0.01) + 1 premium request |
| Lockdown | only `Bash(e2e *)` + `Read(./shots/**)`; reads confined to the cwd | only `shell(e2e:*)`; `--available-tools=bash,read_bash,view`; `--disallow-temp-dir`; `env -i` |
| Report | `--json-schema` structured output | JSON parsed from the final message |
| Typical run | $0.003–0.005 | $0.002–0.003 |

Copilot auto-allows `pwd`, `echo`, `which`, `printenv`, `date`, `whoami` and read-only `git` in the cwd; the runner
therefore scrubs its environment and refuses run dirs inside a repo. Copilot also issues calls in parallel; `e2e`
serialises verbs with a lock that spawned processes must not inherit (`spawn` closes it). Use `--model sonnet`
(Claude) or `--model claude-sonnet-5.5` (Copilot) when a small model gets confused on a complex flow.

Limits (env overrides): `E2E_BUDGET` USD 4, `E2E_MAX_CALLS` 120, `E2E_MAX_SHOTS` 24, `E2E_TIMEOUT` 3600 s; per verb
`wait` ≤ 180 s, `log` ≤ 100 lines (800 chars each). Teardown runs on every exit.

`--source DIR` switches to **white-box** mode (Copilot only): the tester may also read DIR. Use the
`whitebox-e2e` skill for it (`../whitebox-e2e/SKILL.md`); without `--source` nothing changes.

`--scout DIR` (with `--engine copilot --source`) runs a **scout** that drafts a scenario instead of judging one. Do not
call it directly: the `discover-e2e` and `instrument-e2e` skills wrap it. DIR holds `brief.md`, `draft.schema.json`
and optionally `check.jq`, the jq filter a valid draft passes (default: a scenario draft). The scout gets three extra verbs, refused in other modes:
`grep 'REGEX' [N]` (run logs), `sql 'ONE STATEMENT'` (SELECT/PRAGMA through `profile_query`; writes through
`profile_fixture FILE live`, refused when the DB backup failed) and `try-action 'LINE'` (`profile_action`). Applied
writes and actions are recorded in `priv/stimuli.log`. Optional profile hooks: `PRODUCT_MAP` (default
`$STATE_DIR/maps/<profile>.md`), `SCOUT_HINTS`, `profile_query`. Scout limits: `E2E_SCOUT_BUDGET` USD 0.5, 200
calls, 40 shots.

## 4. Report

The runner prints `report.md`: verdict, step table, ≤ 2 screenshot paths, key log lines, and the **total cost**,
turns, `e2e` calls, screenshots, wall time and denied tool calls. It appends one line (with `profile`) to
`$STATE_DIR/e2e-runs.jsonl` (default `~/.local/state/blackbox-e2e/`) and prints the cumulative cost.

Every run that reached the tester or scout (any verdict) also appends one line to `$STATE_DIR/usage.jsonl`:
`{date, skill, engine, model, cost_usd, wall_s}`. It holds nothing about the scenario (no title, profile, target,
verdict or path). `skill` is `$E2E_SKILL` (set by the discover-e2e, whitebox-e2e and instrument-e2e wrappers), else
`whitebox-e2e` with `--source`, else `blackbox-e2e`. `bin/e2e-usage [--since YYYY-MM-DD] [--json]` prints runs, total
and mean cost per skill, and the grand total (`STATE_DIR=…` for a profile that sets its own).

On FAIL, look at the screenshot and log lines yourself before blaming the product: a vague step or a wrong regex
is fixed in the scenario. Denied tool calls mean the tester tried to leave its box; mention them.

A step is `DEVIATION` when its criterion held but the screen differed from the step text. The verdict can still be
PASS. Report each deviation to the user next to the verdict: it is either a scenario to fix or a behaviour to confirm.

## Files

`bin/e2e-run.sh` runner · `bin/e2e` tester verbs · `bin/e2e-lint.sh` · `bin/e2e-usage` cost per skill ·
`lib/stack.sh` profile helpers · `profiles/` built-in profiles · `templates/brief.md` (tester brief) ·
`templates/report.schema.json` · `templates/scenario.example.md`. A run dir holds `sandbox/` (the tester's cwd: `shots/` only) and `priv/` (shim,
`e2e.env`, prompt, process output, `calls.log`); `result.json(l)` is the raw tester output, `tester.json` normalised.

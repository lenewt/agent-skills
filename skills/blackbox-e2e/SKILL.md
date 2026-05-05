---
name: blackbox-e2e
description: Black-box end-to-end test of any GUI application (local X11 under Xvfb, or a remote X11 device over ssh), run by a separate locked-down tester (`claude -p` on Haiku, or Copilot CLI on GPT-6 Luna) that cannot read source code. Only an `e2e` command is available to it (start/stop, screenshots, taps, declared log patterns, declared SQL fixtures). Use for E2E, smoke or acceptance tests of a change, especially when the tester must not see the code. Reports PASS/FAIL per step with the total cost. A project plugs in its app with a profile (a small bash file).
---

# blackbox-e2e: black-box E2E through a separate, locked-down tester

You (the dev session) **author** a behavioural scenario. `bin/e2e-run.sh` **runs** it in a fresh, headless tester
whose only tools are `e2e <verb>` (a shim on its PATH) and a file viewer limited to its own screenshots. The tester
never sees the code, the paths or the build. A **profile** adapts the target app: how to start and stop it, where
its logs are, and how to apply fixtures. Requires the `ui-drive` skill (`~/.claude/skills/ui-drive/bin/uidrive`), plus
`jq`, `perl`, ImageMagick `convert`, `flock` and `Xvfb`/`xdotool` for local apps.

## 1. Pick or write a profile

| Profile | For | Key options |
|---|---|---|
| `x11-command` (built in) | any local X11 app under its own Xvfb | `--set cmd="…"` (required), `desc=`, `size=WxH`, `display=:97`, `cwd=`, `log="…"`, `db=` |
| `ssh-x11-systemd` (built in) | a remote X11 device whose app is a systemd unit | `--host U@H` (required), `--set unit=…` (required), `desc=`, `log=`, `db=`, `boot=30`, `real=1` |
| project profile | anything else, or an app with several processes | a `.sh` file in a dir listed in `E2E_PROFILE_PATH` |

Profile contract: the top level holds only assignments and function definitions. It is sourced by the runner and by
every `e2e` call. `lib/stack.sh` provides `spawn`, `kill_group`, `kill_all_groups`, `groups_status`, `group_alive`,
`wait_for`, `xvfb_start`, `port_busy`, `rsh`, `ui_geom`, `sqlite_backup/restore/apply`, `die` (a verb fails) and
`blocked` (setup cannot run, exit 3).

```bash
PRODUCT_DESC="…"   REAL_DEVICE=0|1            # one line for the tester; 1 adds "taps have physical effects"
UI_TARGET=local|U@H   UI_DISPLAY=:99   SCREEN_W=…   SCREEN_H=…    # or call ui_geom in profile_setup
LOG_HOST=local|U@H   LOG_FILES=(…)            # `e2e log` only reads the lines written during the run
LINT_PATTERNS=(…)   STATE_DIR=…   PROFILE_VARS=(…)   # product names to refuse; ledger/lock dir; vars setup computes
profile_setup        # runner: check the build, compute PROFILE_VARS; blocked "…" when it cannot run
profile_start / profile_stop / profile_status
profile_fixture FILE pre|live ; profile_db_backup ; profile_db_restore    # optional: SQL fixtures
profile_teardown     # optional (default: profile_stop, then the DB restore when fixtures ran)
```

Copy `profiles/x11-command.sh` as a starting point. `--set key=value` reaches the profile as `$E2E_SET_key`, and
`--host` as `$E2E_HOST`.

## 2. Write the scenario (behaviour only)

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
  `LINT_PATTERNS`). Describe what a person at the screen sees; put protocol evidence in log patterns.
- Name controls by their look and position ("the rightmost of the three layout icons"). If a step is *meant* to be
  refused, say so explicitly, or a careful model will skip it to obey Safety.
- 3 to 15 steps, each with one observable criterion; at most 12000 bytes. Example: `templates/scenario.example.md`.
- Fixtures: a separate SQL file with `-- @fixture <name>` blocks. `setup` is applied before start; the others are
  offered to the tester by name only. The DB is backed up first and restored at teardown.

## 3. Run

```bash
~/.claude/skills/blackbox-e2e/bin/e2e-run.sh <scenario.md> [--profile NAME|FILE] [--host U@H] [--set k=v]... \
    [--fixtures f.sql] [--engine claude|copilot] [--model M] [--budget USD] [--out DIR] [--source DIR]
# e.g. the demo:
~/.claude/skills/blackbox-e2e/bin/e2e-run.sh ~/.claude/skills/blackbox-e2e/templates/scenario.example.md \
    --set cmd="xcalc -geometry 400x560+0+0" --set size=400x560 --set desc="a desktop calculator (xcalc)"
```

Run it in the foreground (a run usually takes 20–90 s). Do not watch the tester. Exit codes: 0 = PASS, 1 = FAIL
or BLOCKED, 2 = usage, 3 = BLOCKED before the tester started (busy lock, no build, unreachable device).
Run dirs go to `$CLAUDE_SCRATCHPAD` or `$TMPDIR`, and must not be inside a git repository (the runner refuses).

| | `claude` (default) | `copilot` |
|---|---|---|
| CLI and model | `claude -p --restricted`, `haiku` | Copilot CLI `copilot -p`, `gpt-6-luna` |
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
`whitebox-e2e` skill for it (`~/.claude/skills/whitebox-e2e/SKILL.md`); without `--source` nothing changes.

## 4. Report

The runner prints `report.md`: verdict, step table, ≤ 2 screenshot paths, key log lines, and the **total cost**,
turns, `e2e` calls, screenshots, wall time and denied tool calls. It appends one line (with `profile`) to
`$STATE_DIR/e2e-runs.jsonl` (default `~/.local/state/blackbox-e2e/`) and prints the cumulative cost.

On FAIL, look at the screenshot and log lines yourself before blaming the product: a vague step or a wrong regex
is fixed in the scenario. Denied tool calls mean the tester tried to leave its box; mention them.

## Files

`bin/e2e-run.sh` runner · `bin/e2e` tester verbs · `bin/e2e-lint.sh` · `lib/stack.sh` profile helpers ·
`profiles/` built-in profiles · `templates/brief.md` (tester brief) · `templates/report.schema.json` ·
`templates/scenario.example.md`. A run dir holds `sandbox/` (the tester's cwd: `shots/` only) and `priv/` (shim,
`e2e.env`, prompt, process output, `calls.log`); `result.json(l)` is the raw tester output, `tester.json` normalised.

---
name: whitebox-e2e
description: White-box end-to-end test of a GUI application by a separate Copilot CLI tester that may READ the source tree (file viewer, grep, glob, read-only git history) to locate controls, log messages and expected behaviour, but cannot write files or run anything except the `e2e` command. Same profiles, scenarios and report as blackbox-e2e. Use when a test needs code knowledge (verify a specific change, find the log line a feature emits, check an edge case the UI hides). Copilot CLI only; for a tester that must not see the code, use blackbox-e2e.
---

# whitebox-e2e: E2E with read-only source access (Copilot CLI only)

Paths in this file (`bin/…`, `templates/…`, `../<skill>/…`) are relative to this skill's folder, wherever it is installed.

This is `blackbox-e2e` in white-box mode. Read the sibling skill's `../blackbox-e2e/SKILL.md` first: profiles, scenario
format, limits, report and engines are the same. Only the differences are below.

## Run

```bash
bin/e2e-run.sh <scenario.md> [--source DIR] [--profile …] [--set k=v]… \
    [--fixtures f.sql] [--model M] [--budget USD]
```

`--source` defaults to `$E2E_SOURCE`, then to the git checkout of the current directory. The engine is always
`copilot` (default model `gpt-6-luna`); the runner refuses white-box mode with `--engine claude`, because
`claude -p --restricted` cannot grant read access to a second tree while keeping everything else denied. Project
profiles work unchanged (point `E2E_PROFILE_PATH` at the project's profile folder).

## What the tester gets, in addition to blackbox-e2e

| Access | How |
|---|---|
| Read the source tree | `--add-dir <source>`: `view`, `grep`, `glob`; read-only shell commands on it (e.g. `cat`) are auto-allowed by Copilot |
| Source history | `e2e git log\|show\|diff\|blame\|grep [ARGS]` run in the source (no pager, no external diff/textconv, 400 lines max). Refused: `--output`, `--no-index`, `--contents`, `-O`/`--open-files-in-pager`, `--ext-diff`, `--textconv`, `--exec`, `--upload-pack` |
| Still denied | creating or editing files (no create/edit tool), any shell command other than `e2e` and Copilot's read-only auto-allows, paths outside the source tree and its own sandbox, the network tools |

The brief tells the tester to judge PASS/FAIL **by what the application shows and logs, not by what the code says**:
the source is for finding things, not a substitute for observing them.

## Writing white-box scenarios

- The lint only checks structure here: steps may name classes, functions, files and log formats.
- Point at the change: "the change under test is the last commit (`e2e git show HEAD --stat`)" or a branch range.
- Prefer steps that use the code to make an observation sharper, e.g. "find which message carries the new
  field, then confirm via a log pattern that it is sent when the screen that shows it opens".
- Reading code costs tokens: a white-box run costs about 2× the same black-box run (measured with GPT-6 Luna).
  Keep the step list focused; the `--budget` cap (AI credits = USD × 100) still applies.
- Use it only when the tester must *derive* what to check (a loose "verify the change under test" scenario, a
  branch to reach through the UI, a log format to discover). When the author already wrote precise steps and log
  patterns, white-box adds cost and nothing else: in the first comparison it only rediscovered names the scenario
  had already given it. Small models also grade code-derived claims leniently; prefer `--model claude-sonnet-5.5`
  when a step compares the logs against something read in the code, and require the exact log line as evidence.

## Report

Same report and ledger as blackbox-e2e. The header and the ledger line carry `white-box`.

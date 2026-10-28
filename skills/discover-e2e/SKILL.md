---
name: discover-e2e
description: Draft a black-box E2E scenario (steps, log patterns, SQL fixtures, actions) for a change with a cheap, separate Copilot CLI scout that reads the source read-only and drives the app only through blackbox-e2e's `e2e` verbs, then optionally verify the draft with the real tester. Use before a blackbox-e2e or whitebox-e2e run whenever a scenario must be written or rewritten, so the expensive dev session never explores the UI, logs or DB itself. Proposes product-map additions that the author accepts.
---

# discover-e2e: let a cheap scout write the E2E scenario

A blackbox-e2e tester run costs about $0.005. Writing its scenario in the dev session costs orders of magnitude more:
every screenshot, log grep and SQL try is one more call on a context of several hundred thousand tokens (one measured run: Opus
calls at $0.4–0.9 each, dozens of them). `bin/discover-e2e` moves that exploration into a **scout**: a separate
Copilot CLI process (gpt-6-luna by default), locked down like the white-box tester. It may read the source (read-only)
and call `e2e` verbs, including scout-only `grep`, `sql` and `try-action`. It returns a draft. The dev session
launches it, reads a few small files and decides.

**Cost rule: the author never drives the UI, greps run logs or opens screenshots to write a scenario.** If the draft
is wrong, rerun the scout with a sharper `--goal` or `--ticket`, or edit the draft text. Do not explore yourself.

## Run

```bash
~/.claude/skills/discover-e2e/bin/discover-e2e --profile NAME|FILE [--change RANGE] [--goal "…"] [--ticket FILE] \
  [--source DIR] [--host U@H] [--set KEY=VALUE]... [--model claude-sonnet-5.5] [--budget USD] [--out DIR] [--verify]
```

- `--change`: the commits under test (default `@{upstream}..HEAD`, else `HEAD~1..HEAD`). The scout gets the log,
  the diff stat, the moved submodules' logs and the uncommitted status, and reads the code itself.
- `--goal`: one line, what the scenario must show (default: the first commit subject). `--ticket`: a text export
  of the ticket (6000 bytes).
- `--set`/`--host`: the same profile options the tester will get. They are passed to the scout and to `--verify`,
  and listed in the scout's prompt, because the tester starts from them and the draft fixtures only.
- `--verify`: run the draft once through the black-box tester (Copilot) right after.
- `--source` defaults to the current git root. The run dir (`--out`, default a temp dir) must not be inside a repo.
- Limits: `E2E_SCOUT_BUDGET` USD 0.5, 200 `e2e` calls, 40 screenshots.

Project profiles come through `E2E_PROFILE_PATH`, as for blackbox-e2e.

## Read the output (only these files)

The wrapper prints a short summary: scout cost, step and fixture counts, lint, map additions, open questions, and the
`--verify` verdict. The draft dir holds:

| File | Read it? |
|---|---|
| `scenario.md`, `fixtures.sql` | yes: the draft, lint-clean, ready for `e2e-run.sh` |
| `open-questions.md` | yes: what the scout could not observe (decide or ask the user) |
| `map-additions.md` | yes: proposed product-map facts with evidence |
| `discovery.md` | when a check warns: evidence per step, and every stimulus (`sql`/`action`) the scout applied, in order |
| `verify/report.md` | when `--verify` failed |
| `scout/` | no (raw scout run, screenshots, `calls.log`) |

`check: stimuli … lack verbatim` lists SQL or action lines the scout applied but the fixtures do not contain. It is
fine when the draft merged them into another statement. Otherwise the draft depends on state the tester will not have.

Then run the draft as usual with blackbox-e2e (or whitebox-e2e). A FAIL in `--verify` with a vague step or regex is
a draft defect: rerun the scout, or fix the text, before you blame the product.

## Product map

Each profile has a product map (`PRODUCT_MAP`, default `$STATE_DIR/maps/<profile>.md`, template
`templates/map.example.md`): screens, labels, log formats, fixtures, actions and traps that hold across changes. The
scout reads it first and proposes additions with evidence. Accept the ones you trust:

```bash
discover-e2e --accept-map DRAFT_DIR [--only 1,3]
```

The map's `## Safety` section is copied into every task: its `rect:` lines bind the scout as they bind the tester.

## Profile hooks (optional, see blackbox-e2e)

`PRODUCT_MAP`, `SCOUT_HINTS` (free text for the scout: log formats, code path, fixture tables) and `profile_query`
(read-only SQL for `e2e sql 'SELECT …'`). Write statements go through `profile_fixture FILE live`. They are refused
when the runner could not back up the DB.

## Measured

A measured run (desktop): scout $0.042 (80 turns, 59 calls, 12 shots, 9 min), verify PASS $0.005. The
first scout version dropped an action from the draft and the verify run failed. The brief now requires every
applied stimulus to be in the draft, and the wrapper flags the ones that are missing.

## Files

`bin/discover-e2e` wrapper · `bin/missing-stimuli` stimulus check · `templates/brief.md` scout brief ·
`templates/draft.schema.json` · `templates/map.example.md`. Scout mode lives in blackbox-e2e
(`e2e-run.sh --scout DIR`, scout verbs in `bin/e2e`).

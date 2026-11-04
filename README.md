# agent-skills

General-purpose agent skills for Claude Code and the GitHub Copilot CLI.

| Skill | What it does | Tools |
|---|---|---|
| `blackbox-e2e` | Black-box E2E tests of any GUI app (local X11 under Xvfb, or a remote X11 device over ssh), run by a separate locked-down tester (`claude -p` Haiku or Copilot CLI Claude Haiku 5.5) that cannot read source code. Profiles adapt the app; reports PASS/FAIL per step with the total cost. | Claude, Copilot |
| `whitebox-e2e` | Same, but the tester (Copilot CLI only) may read the source tree, still without writing or running anything else. | Claude, Copilot |
| `discover-e2e` | Drafts a `blackbox-e2e` scenario (steps, log patterns, SQL fixtures, actions) with a cheap Copilot CLI scout that reads the source read-only and drives the app through the `e2e` verbs, then optionally verifies the draft with the real tester. Proposes product-map additions. | Claude, Copilot |
| `instrument-e2e` | Equips the product under test so scenarios can observe and stimulate what the screen hides: a cheap Copilot CLI scout writes a plan for debug lines (`E2E <event> k=v`), hooks (`E2E ready`) and test-only puppet points (a Unix-socket line protocol driven by `@action` blocks). Snippets for Qt/C++, Node, Python and shell/systemd, all gated by a build flag and an env var. | Claude, Copilot |
| `ui-drive` | `uidrive` CLI: screenshots, taps, swipes and recordings on local or remote X11 displays. `blackbox-e2e` depends on it. | Claude, Copilot |
| `board-discovery` | Read-only inventory of an embedded Linux board over serial, ssh, adb or locally (`devsh` transport + `discover` snapshots, per-app deep-dives, drift diffs, workspace-to-board matching), then a method and templates to generate a board-specific skill. Needs `pyserial` for serial targets. | Claude, Copilot |
| `serial-xfer` | `sxfer` CLI: push/pull a file to or from an embedded Linux board over a serial console as base64 (gzip, chunked resume, retries, sha256/md5 check) for boards with no network and no lrzsz; also works over ssh/adb/local. Depends on `board-discovery` (uses its `devsh` transport); needs `pyserial` for serial targets. | Claude, Copilot |

## Install

```bash
./install.sh             # link skills/* into ~/.claude/skills and ~/.copilot/skills (per skills.txt)
./install.sh --dry-run   # show what it would do
./install.sh --migrate   # replace existing real skill folders that are identical to the repo copy
```

Edit the skills here; the installed paths are symlinks. Project-specific profiles for `blackbox-e2e` live in
their own projects (point `E2E_PROFILE_PATH` at them).

Requirements: `jq`, `perl`, ImageMagick `convert`, `flock`, `Xvfb`, `xdotool`, `ffmpeg`; `claude` and/or `copilot` CLI.

# agent-skills

General-purpose agent skills for Claude Code and the GitHub Copilot CLI.

| Skill | What it does | Tools |
|---|---|---|
| `blackbox-e2e` | Black-box E2E tests of any GUI app (local X11 under Xvfb, or a remote X11 device over ssh), run by a separate locked-down tester (`claude -p` Haiku or Copilot CLI GPT-6 Luna) that cannot read source code. Profiles adapt the app; reports PASS/FAIL per step with the total cost. | Claude, Copilot |
| `whitebox-e2e` | Same, but the tester (Copilot CLI only) may read the source tree, still without writing or running anything else. | Claude, Copilot |
| `ui-drive` | `uidrive` CLI: screenshots, taps, swipes and recordings on local or remote X11 displays. `blackbox-e2e` depends on it. | Claude |
| `board-discovery` | Read-only inventory of an embedded Linux board over serial, ssh, adb or locally (`devsh` transport + `discover` snapshots, per-app deep-dives, drift diffs, workspace-to-board matching), then a method and templates to generate a board-specific skill. Needs `pyserial` for serial targets. | Claude, Copilot |

## Install

```bash
./install.sh             # link skills/* into ~/.claude/skills and ~/.copilot/skills (per skills.txt)
./install.sh --dry-run   # show what it would do
./install.sh --migrate   # replace existing real skill folders that are identical to the repo copy
```

Edit the skills here; the installed paths are symlinks. Project-specific profiles for `blackbox-e2e` live in
their own projects (point `E2E_PROFILE_PATH` at them).

Requirements: `jq`, `perl`, ImageMagick `convert`, `flock`, `Xvfb`, `xdotool`, `ffmpeg`; `claude` and/or `copilot` CLI.

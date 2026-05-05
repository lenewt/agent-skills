#!/usr/bin/env bash
# whitebox-e2e: blackbox-e2e in white-box mode. The tester (Copilot CLI only) may read the
# source tree, still without writing files or running anything but `e2e`.
#
#   e2e-run.sh SCENARIO.md [--source DIR] [blackbox-e2e options...]
#
# --source defaults to $E2E_SOURCE, then to the git checkout of the current directory.
set -euo pipefail
SCEN=${1:?usage: e2e-run.sh SCENARIO.md [--source DIR] [blackbox-e2e options...]}; shift
# The runner takes the last --source/--engine given, so a caller's --source wins; a
# caller's --engine claude is refused there (white-box is Copilot only).
case " $* " in
    *" --source "*) src=() ;;
    *)  SRC=${E2E_SOURCE:-$(git rev-parse --show-toplevel 2> /dev/null || true)}
        [ -n "$SRC" ] || { echo "whitebox-e2e: not in a git checkout; pass --source DIR" >&2; exit 2; }
        src=(--source "$SRC") ;;
esac
exec "$HOME/.claude/skills/blackbox-e2e/bin/e2e-run.sh" "$SCEN" --engine copilot "${src[@]}" "$@"

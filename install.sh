#!/usr/bin/env bash
# install.sh [--migrate] [--dry-run]: link this repo's skills into the agent tools.
#
# skills.txt lists "<skill> <tools>" (tools: claude, copilot, comma-separated). Each skill is
# linked as ~/.claude/skills/<skill> and/or ~/.copilot/skills/<skill>. Existing links are
# repointed. An existing real folder is replaced only with --migrate, and only when it is
# identical to the repo copy (diff -r), so nothing is lost.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE=0 DRY=0
for a in "$@"; do
    case "$a" in
        --migrate) MIGRATE=1 ;;
        --dry-run) DRY=1 ;;
        *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
done
run() { if [ "$DRY" = 1 ]; then echo "would: $*"; else "$@"; fi; }

# link_one SRC DEST: make DEST a symlink to SRC.
link_one() {
    local src=$1 dest=$2
    if [ -L "$dest" ]; then
        [ "$(readlink "$dest")" = "$src" ] && { echo "ok       $dest"; return; }
        run ln -sfn "$src" "$dest"; echo "repoint  $dest -> $src"
    elif [ -e "$dest" ]; then
        # Safe to replace when nothing in DEST would be lost: files only in the repo copy are fine.
        if [ "$MIGRATE" = 1 ] && ! diff -rq "$dest" "$src" 2>&1 | grep -qv "^Only in $src"; then
            run rm -rf "$dest"; run ln -s "$src" "$dest"; echo "migrate  $dest -> $src"
        else
            echo "SKIP     $dest is a real file/folder$( [ "$MIGRATE" = 1 ] && echo " that differs from $src")" >&2
            return 1
        fi
    else
        run mkdir -p "$(dirname "$dest")"; run ln -s "$src" "$dest"; echo "link     $dest -> $src"
    fi
}

rc=0
while read -r skill tools; do
    case "$skill" in ''|'#'*) continue ;; esac
    [ -d "$REPO/skills/$skill" ] || { echo "skills.txt: no skills/$skill" >&2; rc=1; continue; }
    for t in ${tools//,/ }; do
        case "$t" in
            claude)  link_one "$REPO/skills/$skill" "$HOME/.claude/skills/$skill" || rc=1 ;;
            copilot) link_one "$REPO/skills/$skill" "$HOME/.copilot/skills/$skill" || rc=1 ;;
            *) echo "skills.txt: unknown tool '$t' for $skill" >&2; rc=1 ;;
        esac
    done
done < "$REPO/skills.txt"
exit $rc

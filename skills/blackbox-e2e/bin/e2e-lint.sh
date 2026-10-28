#!/usr/bin/env bash
# e2e-lint.sh SCENARIO.md [EXTRA_REGEX...]: refuse scenarios that would leak source code
# to the black-box tester, and check the structure the runner relies on. EXTRA_REGEX are
# the profile's LINT_PATTERNS (product-specific names). Prints each hit with its line
# number; exit 1 on any hit.
set -uo pipefail
f=${1:?usage: e2e-lint.sh SCENARIO.md [EXTRA_REGEX...]}; shift
hits=0
hit() { echo "lint: $*"; hits=$((hits + 1)); }

extra=()
for re in "$@"; do extra+=(-e "$re"); done
# Keywords hit only in code shape, so prose such as "return to the grid" or "the import entry" passes.
name='[A-Za-z_][A-Za-z0-9_]*'
keyword_code=(
    -e "\b(void|const|class|struct|function|def|emit)[[:space:]]+([A-Za-z_&*][A-Za-z0-9_&*<>:]*[[:space:]]+)?[&*]?$name(\(|[[:space:]]*(\{|=[^=]|:[[:space:]]*(public|private|protected)\b))"
    -e '\breturn[[:space:]]+[^[:space:];]+;' -e '\b(return|emit)[[:space:]]*\('
    -e "\bimport[[:space:]]+$name(\.$name)+" -e "\bimport[[:space:]]+[A-Z]$name[[:space:]]+[0-9]"
    -e '\b(Q_INVOKABLE|Q_PROPERTY)\b')
# Source-shaped content. Log-pattern lines may hold regex syntax but not code.
# E2E_LINT_STRUCTURE_ONLY=1 (white-box runs, where the tester may read the source) skips it.
[ "${E2E_LINT_STRUCTURE_ONLY:-0}" = 1 ] ||
while IFS= read -r m; do hit "source-like content: $m"; done < <(grep -nE \
    -e '```' -e '#include' -e '::' -e '(^|[^A-Za-z])src/' -e '/home/' -e '/Users/' \
    -e '\.(c|cc|cpp|h|hpp|qml|js|jsx|ts|tsx|py|java|kt|go|rs|pro|pri|qrc|gradle|cmake)\b' \
    "${keyword_code[@]}" -e '\b[a-z]+[A-Z][A-Za-z]*\(\)' \
    "${extra[@]}" "$f")

grep -qE '^# Scenario: .+' "$f" || hit "missing '# Scenario: <title>'"
grep -qE '^Target: [A-Za-z0-9][A-Za-z0-9_.-]*[[:space:]]*$' "$f" || hit "missing 'Target: <profile name>'"
grep -qE '^## Steps[[:space:]]*$' "$f" || hit "missing '## Steps'"
awk '/^## /{ on = ($0 ~ /^## Steps/); next } on && /^[0-9]+\./' "$f" | grep -qv 'PASS if' \
    && hit "every step needs a 'PASS if <observable>' criterion"
[ "$(wc -c < "$f")" -le 12000 ] || hit "scenario longer than 12000 bytes; split it"
# Self-graded oracle: a fixture or action that checks the product and logs "PASS …" turns the tester into a relay.
# Log patterns must match what the product writes; protocol assertions belong in unit tests.
while IFS= read -r m; do hit "log pattern matches a test verdict word (PASS/FAIL), not product output: $m"; done < <(
    awk '/^## /{ on = ($0 ~ /^## Log patterns/); next } on' "$f" | grep -E '\b(PASS|FAIL|FAILED)\b')

if [ "$hits" -eq 0 ]; then echo "lint: ok"; else exit 1; fi

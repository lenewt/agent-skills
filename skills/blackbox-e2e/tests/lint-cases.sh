#!/usr/bin/env bash
# lint-cases.sh: check e2e-lint.sh on single steps. Prose must pass, code must be refused. Exit 1 on any mismatch.
set -uo pipefail
LINT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/e2e-lint.sh"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
failures=0

prose=(
    "Apply the second fixture, return to the main menu if needed and open Settings again"
    "Open the import entry (\"Import\" / \"From file\"), take a screenshot"
    "Go back to the main menu (use a back control, or wait for it to return by itself)"
    "Pick the first item in the list, then return it (if needed)"
    "Keep the const value shown; return to Settings and open the function list"
    "Return to home; emit a beep by tapping the bell"
)
code=(
    "Check that return m_itemCount; is hit"
    "void setItemCount(int count)"
    "class ItemFilter : public QObject {"
    "const QString name = foo"
    "emit itemCountChanged();"
    "function onClicked() {"
    "def handle(self):"
    "import QtQuick 2.15"
    "import com.example.app;"
    "struct Item {"
    "Q_PROPERTY(int count READ count)"
    "return(value)"
    "const auto &item = items"
)

# check STEP EXPECTED_STATUS: lint a one-step scenario holding STEP.
check() {
    printf '# Scenario: lint case\nTarget: demo\n## Steps\n1. %s -- PASS if the screen shows it\n' "$1" > "$tmp"
    "$LINT" "$tmp" > /dev/null
    local status=$?
    [ "$status" = "$2" ] || { echo "MISMATCH (exit $status, want $2): $1"; failures=$((failures + 1)); }
}

for step in "${prose[@]}"; do check "$step" 0; done
for step in "${code[@]}"; do check "$step" 1; done
[ "$failures" -eq 0 ] && echo "lint-cases: ok (${#prose[@]} prose, ${#code[@]} code)"
[ "$failures" -eq 0 ]

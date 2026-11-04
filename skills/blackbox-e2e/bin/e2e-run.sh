#!/usr/bin/env bash
# e2e-run.sh: run one black-box E2E scenario through a separate, locked-down tester
# (`claude -p`, or `copilot -p` with --engine copilot) that can only call `e2e` (on its
# PATH) and read its own screenshots. A profile adapts the target app (start/stop, logs,
# fixtures).
#
#   e2e-run.sh SCENARIO.md [--profile NAME|FILE] [--host USER@HOST] [--set KEY=VALUE]...
#              [--fixtures FILE.sql] [--engine claude|copilot] [--model M] [--budget USD]
#              [--out DIR] [--source DIR] [--explore [--explore-fixture NAME]...] [--scout DIR]
#
# --explore is for the author, before writing the steps: no tester and no cost. It starts the
# stack (with the setup fixture), saves shots/start.png, then applies each --explore-fixture
# in order and saves shots/after-NAME.png. Write steps against what those screenshots show.
#
# --source DIR is white-box mode (Copilot only): the tester may also read DIR (file viewer,
# grep, glob, `e2e git log|show|diff|blame|grep`), still without writing or running anything.
#
# --scout DIR is discovery mode (discover-e2e and instrument-e2e, Copilot + --source only):
# SCENARIO.md is a task stub, DIR holds brief.md, draft.schema.json and optionally check.jq (the
# jq filter a valid draft passes), the scout gets extra verbs (grep, sql, try-action), and the
# run writes <run>/draft.json instead of a verdict.
#
# The profile defaults to the scenario's "Target: <name>", looked up in $E2E_PROFILE_PATH
# (colon-separated dirs), then in this skill's profiles/. Prints the per-step verdict, the
# total cost and wall time, writes <run>/report.md and appends to $STATE_DIR/e2e-runs.jsonl
# and to the global usage ledger $E2E_USAGE_LOG (default ~/.local/state/blackbox-e2e/usage.jsonl,
# whatever the profile's STATE_DIR): skill (= $E2E_SKILL), engine, model, cost, wall time and the
# calling session's id and cumulative cost (bin/session-cost), nothing about the scenario.
# The engine defaults to $E2E_ENGINE, then to the calling session's tool (copilot inside a Copilot session).
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(dirname "$BIN")"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 && !/shellcheck/ { sub(/^# ?/, ""); print }' "$0"; exit 2; }
# session_engine: the caller's own tool, so the run bills the subscription the session already uses.
session_engine() {
    if [ -z "${CLAUDECODE:-}" ] && [ -n "${COPILOT_CLI:-}${COPILOT_AGENT_SESSION_ID:-}" ]; then echo copilot
    else echo claude; fi
}
SCEN=${1:-}; [ -f "$SCEN" ] || usage; shift
PROFILE_ARG="" FIXTURES_IN="" OUT="" SOURCE="" EXPLORE=0 EXPLORE_FIXTURES=() SCOUT="" BUDGET="" ENGINE=${E2E_ENGINE:-} MODEL=${E2E_MODEL:-}
export E2E_HOST=${E2E_HOST:-}
while [ $# -gt 0 ]; do
    case "$1" in
        --profile)  PROFILE_ARG=$2; shift 2 ;;
        --host)     E2E_HOST=$2; shift 2 ;;
        --set)
            [[ "$2" =~ ^([a-z][a-z0-9_]*)=([^$'\n']*)$ ]] || { echo "--set: key=value (key: [a-z][a-z0-9_]*)" >&2; exit 2; }
            export "E2E_SET_${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"; shift 2 ;;
        --fixtures) FIXTURES_IN=$2; shift 2 ;;
        --engine)   ENGINE=$2; shift 2 ;;
        --model)    MODEL=$2; shift 2 ;;
        --budget)   BUDGET=$2; shift 2 ;;
        --out)      OUT=$2; shift 2 ;;
        --source)   SOURCE=$(cd "$2" && pwd) || exit 2; shift 2 ;;
        --explore)  EXPLORE=1; shift ;;
        --explore-fixture) EXPLORE=1; EXPLORE_FIXTURES+=("$2"); shift 2 ;;
        --scout)    SCOUT=$(cd "$2" && pwd) || exit 2; shift 2 ;;
        *) usage ;;
    esac
done
if [ -n "$SCOUT" ]; then
    ENGINE=${ENGINE:-copilot}
    if [ "$ENGINE" != copilot ] || [ -z "$SOURCE" ] || [ "$EXPLORE" = 1 ]; then
        echo "--scout needs --engine copilot and --source, without --explore" >&2; exit 2
    fi
    if [ ! -f "$SCOUT/brief.md" ] || [ ! -f "$SCOUT/draft.schema.json" ]; then
        echo "--scout: DIR lacks brief.md or draft.schema.json" >&2; exit 2
    fi
    BUDGET=${BUDGET:-${E2E_SCOUT_BUDGET:-0.5}}
fi
ENGINE=${ENGINE:-$(session_engine)} BUDGET=${BUDGET:-${E2E_BUDGET:-4}}
case "$ENGINE" in
    claude)  MODEL=${MODEL:-haiku} ;;
    copilot) MODEL=${MODEL:-claude-haiku-5.5} ;;
    *) echo "--engine: claude or copilot" >&2; exit 2 ;;
esac
command -v "$ENGINE" > /dev/null || { echo "E2E: BLOCKED ($ENGINE CLI not installed)"; exit 3; }
MODE=black-box
if [ -n "$SOURCE" ]; then
    # Only the Copilot CLI can grant read access to one extra tree (--add-dir) while every
    # write and every other command stays denied; claude --restricted cannot.
    [ "$ENGINE" = copilot ] || { echo "--source (white-box) runs only with --engine copilot" >&2; exit 2; }
    MODE=white-box
    export E2E_LINT_STRUCTURE_ONLY=1
fi
[ -z "$SCOUT" ] || MODE=scout
[ -z "$E2E_HOST" ] || [[ "$E2E_HOST" =~ ^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$ ]] || { echo "--host: USER@HOST" >&2; exit 2; }

# 1. Profile ---------------------------------------------------------------------------
PROFILE_NAME=${PROFILE_ARG:-$(sed -nE 's/^Target: ([A-Za-z0-9][A-Za-z0-9_.-]*).*/\1/p' "$SCEN" | head -1)}
[ -n "$PROFILE_NAME" ] || { echo "no profile: pass --profile or put 'Target: <name>' in the scenario" >&2; exit 2; }
PROFILE=""
if [ -f "$PROFILE_NAME" ]; then
    PROFILE=$(cd "$(dirname "$PROFILE_NAME")" && pwd)/$(basename "$PROFILE_NAME")
    PROFILE_NAME=$(basename "$PROFILE_NAME" .sh)
else
    IFS=: read -r -a dirs <<< "${E2E_PROFILE_PATH:-}"
    for d in "${dirs[@]}" "$SKILL/profiles"; do
        [ -n "$d" ] && [ -f "$d/$PROFILE_NAME.sh" ] && { PROFILE=$(cd "$d" && pwd)/$PROFILE_NAME.sh; break; }
    done
fi
[ -n "$PROFILE" ] || { echo "profile '$PROFILE_NAME' not found (E2E_PROFILE_PATH, $SKILL/profiles)" >&2; exit 2; }

# Profile contract (see SKILL.md): assignments and function definitions only at top level.
UI_TARGET=local UI_DISPLAY=:99 SCREEN_W="" SCREEN_H="" LOG_HOST=local REAL_DEVICE=0
PRODUCT_DESC="a graphical application" STATE_DIR="" LOG_FILES=() LINT_PATTERNS=() PROFILE_VARS=()
PRODUCT_MAP="" SCOUT_HINTS=""
# shellcheck source=../lib/stack.sh
. "$SKILL/lib/stack.sh"
# shellcheck source=/dev/null
. "$PROFILE"
for hook in profile_start profile_stop profile_status; do
    declare -F "$hook" > /dev/null || { echo "profile $PROFILE lacks $hook" >&2; exit 2; }
done

# 2. Lint, lock --------------------------------------------------------------------------
# A draft scenario may still fail the lint while exploring.
# A scout's input is a task stub, not a scenario.
[ "$MODE" = scout ] || "$BIN/e2e-lint.sh" "$SCEN" "${LINT_PATTERNS[@]}" || [ "$EXPLORE" = 1 ]
TITLE=$(sed -nE 's/^# Scenario: (.+)/\1/p' "$SCEN" | head -1)
STATE=${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/blackbox-e2e}
mkdir -p "$STATE"
PRODUCT_MAP=${PRODUCT_MAP:-$STATE/maps/$PROFILE_NAME.md}
exec 9> "$STATE/e2e-${PROFILE_NAME}-${UI_TARGET//[^A-Za-z0-9.]/_}.lock"
flock -n 9 || { echo "E2E: BLOCKED (busy: another e2e-run holds the $PROFILE_NAME/$UI_TARGET lock)"; exit 3; }

# 3. Run directories ---------------------------------------------------------------------
T0=$(date +%s)
if [ -n "$OUT" ]; then RUN=$OUT
else RUN=$(mktemp -d "${CLAUDE_SCRATCHPAD:-${TMPDIR:-/tmp}}/e2e-$(date +%Y%m%d-%H%M%S)-XXXX"); fi
SANDBOX=$RUN/sandbox PRIV=$RUN/priv
mkdir -p "$SANDBOX/shots" "$PRIV/bin"; chmod 700 "$PRIV"
# Copilot auto-allows read-only git in the cwd: the sandbox must not sit inside a repo.
if git -C "$SANDBOX" rev-parse --git-dir > /dev/null 2>&1; then
    echo "E2E: BLOCKED (run dir $RUN is inside a git repository; use --out under the scratchpad or /tmp)"; exit 3
fi
cp "$SCEN" "$PRIV/scenario.md"
FIXTURES="$PRIV/fixtures.sql"
if [ -n "$FIXTURES_IN" ]; then cp "$FIXTURES_IN" "$FIXTURES"; else : > "$FIXTURES"; fi
# shellcheck disable=SC2016  # the shim expands $E2E_BIN at run time
printf '#!/bin/sh\nexec "$E2E_BIN" "$@"\n' > "$PRIV/bin/e2e"; chmod 755 "$PRIV/bin/e2e"
export E2E_PRIV=$PRIV E2E_BIN=$BIN/e2e

# 4. Profile setup, e2e.env --------------------------------------------------------------
if declare -F profile_setup > /dev/null; then profile_setup; fi
[[ "$SCREEN_W" =~ ^[0-9]+$ && "$SCREEN_H" =~ ^[0-9]+$ ]] || blocked "profile did not set SCREEN_W/SCREEN_H"
SKILL_DIR=$SKILL SCENARIO=$PRIV/scenario.md SHOT_WIDTH=400
if [ "$MODE" = scout ]; then MAX_CALLS=${E2E_MAX_CALLS:-200} MAX_SHOTS=${E2E_MAX_SHOTS:-40}
else MAX_CALLS=${E2E_MAX_CALLS:-120} MAX_SHOTS=${E2E_MAX_SHOTS:-24}; fi
{
    declare -p PROFILE PROFILE_NAME SKILL_DIR SANDBOX SCENARIO FIXTURES MAX_CALLS MAX_SHOTS SHOT_WIDTH \
        UI_TARGET UI_DISPLAY SCREEN_W SCREEN_H LOG_HOST LOG_FILES E2E_HOST SOURCE MODE
    for v in "${PROFILE_VARS[@]}" $(compgen -v E2E_SET_ || true); do declare -p "$v"; done
} | sed 's/^declare -x /declare -- /' > "$PRIV/e2e.env"
export PATH="$PRIV/bin:$PATH"

# 5. Fixtures (backup + setup); teardown always restores ----------------------------------
DIRTY=0
teardown() {
    set +e
    if declare -F profile_teardown > /dev/null; then profile_teardown; else profile_stop > /dev/null 2>&1; fi
    [ "$DIRTY" = 1 ] && profile_db_restore && echo "fixtures reverted"
}
if grep -qE '^--[[:space:]]*@action[[:space:]]' "$FIXTURES"; then
    declare -F profile_action > /dev/null || blocked "profile $PROFILE_NAME has no action support (profile_action)"
fi
if grep -qE '^--[[:space:]]*@fixture[[:space:]]' "$FIXTURES"; then
    for hook in profile_fixture profile_db_backup profile_db_restore; do
        declare -F "$hook" > /dev/null || blocked "profile $PROFILE_NAME has no fixture support ($hook)"
    done
    profile_db_backup || blocked "fixture backup failed"
    DIRTY=1
fi
# A scout may change the DB with `e2e sql`: back up when the profile can, else refuse such changes.
if [ "$MODE" = scout ] && [ "$DIRTY" = 0 ]; then
    if declare -F profile_db_backup > /dev/null && profile_db_backup > /dev/null 2>&1; then DIRTY=1
    else : > "$PRIV/no-db-writes"; fi
fi
# usage_log COST WALL: the skills' cost ledger, one line per tester run and nothing about the
# scenario (bin/e2e-usage). Once per run: after the tester, or on INT/TERM once it has started.
# One global file, not under STATE_DIR: profiles that set their own must not split it.
USAGE_LOG=${E2E_USAGE_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/blackbox-e2e/usage.jsonl}
TESTER=0
usage_log() {
    local skill=${E2E_SKILL:-blackbox-e2e} cost=$1 session
    [ "$TESTER" = 1 ] || return 0
    TESTER=logged
    [ -n "${E2E_SKILL:-}" ] || [ "$MODE" != white-box ] || skill=whitebox-e2e
    [[ "$cost" =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || cost=0
    # The caller's session (this process's env, not the tester's); best effort, null if unknown.
    session=$(timeout 3 "$BIN/session-cost" 2> /dev/null) || session=null
    jq -e 'type == "object" or type == "null"' <<< "$session" > /dev/null 2>&1 || session=null
    mkdir -p "$(dirname "$USAGE_LOG")" 2> /dev/null || true
    jq -nc --arg date "$(date -Iseconds)" --arg skill "$skill" --arg engine "$ENGINE" --arg model "$MODEL" \
        --argjson cost "$cost" --argjson wall "$2" --argjson session "$session" \
        '{date:$date, skill:$skill, engine:$engine, model:$model, cost_usd:$cost, wall_s:$wall, session:$session}' \
        >> "$USAGE_LOG" || true
}
trap teardown EXIT
trap 'usage_log "$(jq -r ".cost_usd // 0" "$RUN/tester.json" 2> /dev/null || echo 0)" $(( $(date +%s) - T0 )); exit 130' INT TERM
if grep -qE '^--[[:space:]]*@fixture[[:space:]]+setup\b' "$FIXTURES"; then
    awk '/^--[[:space:]]*@(fixture|action)[[:space:]]/{ on = ($3 == "setup"); next } on' "$FIXTURES" > "$PRIV/fixture.sql"
    profile_fixture "$PRIV/fixture.sql" pre || blocked "setup fixture failed"
fi

if [ "$EXPLORE" = 1 ]; then
    "$BIN/e2e" start || blocked "the stack did not start"
    "$BIN/e2e" shot start || true
    for f in "${EXPLORE_FIXTURES[@]}"; do
        if "$BIN/e2e" fixture "$f"; then "$BIN/e2e" wait 3 > /dev/null; "$BIN/e2e" shot "after-$f" || true; fi
    done
    teardown; trap - EXIT
    echo "explore: screenshots in $SANDBOX/shots (full size: $PRIV/raw-*.png), process output in $PRIV/*.out"
    exit 0
fi

# 6. Tester -------------------------------------------------------------------------------
# Each engine writes $RUN/tester.json, normalised as
# {engine, model, cost_usd, turns, denied, stop, report|null}.
DEVICE_RULE=""
[ "$REAL_DEVICE" = 1 ] && DEVICE_RULE=" The device is real: a tap can have physical effects."
if [ -n "$SOURCE" ]; then
    SOURCE_RULE="You may read the source code under $SOURCE (read-only) to find controls, log messages and the expected behaviour. Judge PASS/FAIL only by what the application shows and logs, not by what the code says."
    VIEW_RULE="- The file viewer, grep and glob: on \`shots/NAME.png\` and on the source tree only. \`e2e git log|show|diff|blame|grep [ARGS]\` reads the source history."
else
    SOURCE_RULE="You have no access to source code and must not try to get any. Judge only what the application shows and logs."
    VIEW_RULE="- The file viewer (Read/view) on \`shots/NAME.png\` only, right after \`e2e shot NAME\`."
fi
BRIEF=$SKILL/templates/brief.md SCHEMA=$SKILL/templates/report.schema.json
[ "$MODE" = scout ] && BRIEF=$SCOUT/brief.md SCHEMA=$SCOUT/draft.schema.json
{
    P=$PRODUCT_DESC D=$DEVICE_RULE C=$MAX_CALLS S=$MAX_SHOTS M=$MODE SR=$SOURCE_RULE VR=$VIEW_RULE perl -pe \
        's/\@PRODUCT\@/$ENV{P}/g; s/\@DEVICE_RULE\@/$ENV{D}/g; s/\@MAX_CALLS\@/$ENV{C}/g; s/\@MAX_SHOTS\@/$ENV{S}/g;
         s/\@MODE\@/$ENV{M}/g; s/\@SOURCE_RULE\@/$ENV{SR}/g; s/\@VIEW_RULE\@/$ENV{VR}/g' \
        "$BRIEF"
    if [ "$ENGINE" = copilot ]; then
        printf '\nYour final message must be only the report as one JSON object (no prose, no code fence) matching this JSON Schema:\n'
        cat "$SCHEMA"
    fi
    if [ "$MODE" = scout ]; then
        [ -z "$SCOUT_HINTS" ] || printf '\n## Profile hints\n%s\n' "$SCOUT_HINTS"
        printf '\n## Run options (the tester gets the same)\n'
        for v in $(compgen -v E2E_SET_ || true); do printf -- '- %s=%s\n' "${v#E2E_SET_}" "${!v}"; done
        [ -n "$(compgen -v E2E_SET_ || true)" ] || echo "(none)"
        if [ -f "$PRODUCT_MAP" ]; then printf '\n## Product map (%s)\n' "$(basename "$PRODUCT_MAP")"; cat "$PRODUCT_MAP"
        else printf '\n## Product map\n(none yet: everything you verify is a map addition)\n'; fi
    fi
    printf '\n\n---\n\nTarget: %s, screen %sx%s.\nDeclared fixtures: %s\n\n' "$PROFILE_NAME" "$SCREEN_W" "$SCREEN_H" \
        "$(sed -nE 's/^--[[:space:]]*@(fixture|action)[[:space:]]+([A-Za-z0-9_-]+).*/\2/p' "$FIXTURES" | grep -vx setup | tr '\n' ' ' || true)"
    cat "$PRIV/scenario.md"
} > "$PRIV/prompt.md"

run_claude() {
    cat > "$PRIV/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(e2e *)", "Read(./shots/**)"],
    "deny": ["Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent"]
  }
}
EOF
    (cd "$SANDBOX" && timeout "${E2E_TIMEOUT:-3600}" claude -p "$(cat "$PRIV/prompt.md")" \
        --restricted --strict-mcp-config --tools Read,Bash \
        --settings "$PRIV/settings.json" --permission-mode dontAsk --permission-prompts none \
        --model "$MODEL" --max-budget-usd "$BUDGET" --no-session-persistence \
        --output-format json --json-schema "$(cat "$SCHEMA")" \
        < /dev/null > "$RUN/result.json" 2> "$PRIV/tester.err")
    RC=$?
    jq -e . "$RUN/result.json" > /dev/null 2>&1 || echo '{}' > "$RUN/result.json"
    jq -c --arg model "$MODEL" '{engine: "claude", model: $model, cost_usd: (.total_cost_usd // 0),
        turns: (.num_turns // 0), denied: ([.permission_denials[]?] | length),
        stop: (.subtype // "no result"), report: (.structured_output // null)}' \
        "$RUN/result.json" > "$RUN/tester.json"
}

run_copilot() {
    # Prompt mode denies every tool call that no --allow-tool rule approves (verified:
    # cat, ../ reads and `e2e x; cat …` are refused). --disallow-temp-dir matters
    # because the run dir lives under /tmp. 1 AI credit = $0.01.
    # USER is unset in some agent hosts (VS Code); set -u would abort the run.
    local E2E_USER=${USER:-$(id -un)}
    local credits
    credits=$(awk -v b="$BUDGET" 'BEGIN { c = int(b * 100); print (c < 30 ? 30 : c) }')
    # Copilot auto-allows pwd, echo, which, printenv, date, whoami and read-only git
    # (file readers, ls, find, cd outside the cwd are denied), so the tester gets a
    # minimal environment: printenv then shows nothing secret.
    local -a envkeep=(HOME="$HOME" USER="$E2E_USER" LOGNAME="${LOGNAME:-$E2E_USER}" PATH="$PATH"
        LANG="${LANG:-C.UTF-8}" TERM=dumb E2E_PRIV="$E2E_PRIV" E2E_BIN="$E2E_BIN")
    local v
    for v in XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS SSH_AUTH_SOCK; do
        [ -n "${!v:-}" ] && envkeep+=("$v=${!v}")
    done
    # White-box: --add-dir makes the source readable (view, grep, glob; read-only shell
    # commands on it are auto-allowed). Writes stay denied: no create/edit tool, no shell rule.
    local -a srcargs=() tools=bash,read_bash,view
    [ -n "$SOURCE" ] && { srcargs=(--add-dir "$SOURCE"); tools=$tools,grep,glob; }
    (cd "$SANDBOX" && env -i "${envkeep[@]}" timeout "${E2E_TIMEOUT:-3600}" copilot -p "$(cat "$PRIV/prompt.md")" \
        --model "$MODEL" --available-tools="$tools" --allow-tool='shell(e2e:*)' "${srcargs[@]}" \
        --no-custom-instructions --disable-builtin-mcps --disallow-temp-dir --no-ask-user \
        --no-auto-update --no-color --max-ai-credits "$credits" \
        --log-dir "$PRIV/copilot-logs" --usage-output-file "$PRIV/copilot-usage.json" \
        --output-format json < /dev/null > "$RUN/result.jsonl" 2> "$PRIV/tester.err")
    RC=$?
    local last rep
    last=$(jq -rs '[.[] | select(.type == "assistant.message") | .data.content // empty] | last // ""' \
        "$RUN/result.jsonl" 2> /dev/null)
    # The report is the outermost {...} of the final message.
    local check='select(.verdict and (.steps | type) == "array")'
    if [ "$MODE" = scout ]; then
        # A scout dir may bring its own check (instrument-e2e); else a scenario draft (discover-e2e).
        check='select((.scenario_md | type) == "string" and (.fixtures_sql | type) == "string")'
        [ ! -f "$SCOUT/check.jq" ] || check=$(cat "$SCOUT/check.jq")
    fi
    rep=$(perl -0ne 'print $1 if /(\{.*\})/s' <<< "$last" | jq -c "$check" 2> /dev/null || true)
    jq -sc --arg model "$MODEL" --argjson rep "${rep:-null}" \
        --slurpfile usage <(cat "$PRIV/copilot-usage.json" 2> /dev/null || echo '{}') '
        {engine: "copilot", model: $model,
         cost_usd: (($usage[0].totalNanoAiu // 0) / 1e9 * 0.01),
         ai_credits: (($usage[0].totalNanoAiu // 0) / 1e9),
         premium_requests: ($usage[0].totalPremiumRequestCost // 0),
         turns: ([.[] | select(.type == "model.call_finished")] | length),
         denied: ([.[] | select(.type == "tool.execution_complete" and .data.error.code? == "denied")] | length),
         stop: ([.[] | select(.type == "result") | "exit \(.exitCode)"] | last // "no result"),
         report: $rep}' "$RUN/result.jsonl" > "$RUN/tester.json" 2> /dev/null \
        || jq -nc --arg model "$MODEL" '{engine: "copilot", model: $model, cost_usd: 0, turns: 0, denied: 0, stop: "unreadable output", report: null}' > "$RUN/tester.json"
}

RC=0 TESTER=1
rm -f "$RUN/tester.json"   # a reused --out: the signal path must not log an old cost
set +e
"run_$ENGINE"
set -e
CALLS=$(cat "$PRIV/calls" 2>/dev/null || echo 0); SHOTS=$(cat "$PRIV/shots" 2>/dev/null || echo 0)
teardown; trap - EXIT

# 7. Report (with total cost) -------------------------------------------------------------
WALL=$(( $(date +%s) - T0 ))
R="$RUN/tester.json"
COST=$(jq -r '.cost_usd' "$R")
usage_log "$COST" "$WALL"
TURNS=$(jq -r '.turns' "$R")
SUB=$(jq -r '.stop' "$R")
REP=$(jq -c '.report // empty' "$R")
EXTRA=$(jq -r 'if .engine == "copilot" then " (\(.ai_credits * 100 | round / 100) AI credits, \(.premium_requests) premium requests)" else "" end' "$R")
if [ "$MODE" = scout ]; then
    if [ -n "$REP" ]; then VERDICT=DRAFT; jq . <<< "$REP" > "$RUN/draft.json"; else VERDICT=BLOCKED; fi
    {
        echo "# Scout: $VERDICT, $TITLE"
        echo
        echo "Profile $PROFILE_NAME ($UI_TARGET) · scout · $ENGINE $MODEL · **total cost \$$(printf '%.4f' "$COST")**$EXTRA · $TURNS turns · $CALLS e2e calls · $SHOTS shots · wall ${WALL}s · denied tool calls $(jq -r '.denied' "$R")"
        echo
        if [ -n "$REP" ]; then echo "draft: $RUN/draft.json"; else echo "scout ended without a draft: $SUB (rc $RC)"; fi
    } > "$RUN/report.md"
    cat "$RUN/report.md"
    jq -nc --arg date "$(date -Iseconds)" --arg title "$TITLE" --arg profile "$PROFILE_NAME" --arg target "$UI_TARGET" \
        --arg verdict "$VERDICT" --arg engine "$ENGINE" --arg model "$MODEL" --argjson cost "$COST" --argjson turns "$TURNS" \
        --argjson calls "$CALLS" --argjson shots "$SHOTS" --argjson wall "$WALL" --arg report "$RUN/report.md" \
        '{date:$date, title:$title, profile:$profile, target:$target, mode:"scout", engine:$engine, model:$model, verdict:$verdict,
          deviations:0, cost_usd:$cost, turns:$turns, calls:$calls, shots:$shots, wall_s:$wall, report:$report}' >> "$STATE/e2e-runs.jsonl"
    [ "$VERDICT" = DRAFT ]; exit
fi
if [ -n "$REP" ]; then
    # The verdict follows the steps (small models mislabel it): any FAIL/SKIPPED step or none at all -> FAIL.
    VERDICT=$(jq -r 'if .verdict == "BLOCKED" then "BLOCKED"
        elif (.steps | length) > 0 and all(.steps[]; .status == "PASS" or .status == "DEVIATION") then "PASS"
        else "FAIL" end' <<< "$REP")
    [ "$VERDICT" = "$(jq -r '.verdict' <<< "$REP")" ] \
        || REP=$(jq -c --arg v "$VERDICT" '.notes = "Verdict \(.verdict) corrected to \($v) from the step statuses. " + .notes | .verdict = $v' <<< "$REP")
else VERDICT=BLOCKED REP=$(jq -nc --arg n "tester ended without a report: $SUB (rc $RC)" '{verdict:"BLOCKED",steps:[],screenshots:[],log_lines:[],notes:$n}'); fi
DENIED=$(jq -r '.denied' "$R")
DEVIATIONS=$(jq '[.steps[]? | select(.status == "DEVIATION")] | length' <<< "$REP")

{
    echo "# E2E: $VERDICT, $TITLE"
    echo
    echo "Profile $PROFILE_NAME ($UI_TARGET) · $MODE · $ENGINE $MODEL · **total cost \$$(printf '%.4f' "$COST")**$EXTRA · $TURNS turns · $CALLS e2e calls · $SHOTS shots · wall ${WALL}s · denied tool calls $DENIED"
    echo
    [ "$DEVIATIONS" = 0 ] || { echo "**$DEVIATIONS step(s) with DEVIATION:** the criterion held, but the screen differed from the step. Relay them to the user, do not report a plain PASS."; echo; }
    echo "| Step | Status | Evidence |"; echo "|---|---|---|"
    jq -r '.steps[] | "| \(.n) | \(.status) | \(.evidence // "" | tostring | gsub("\\|"; "/") | gsub("\n"; " ")) |"' <<< "$REP"
    echo
    jq -r '.screenshots[]? | "- screenshot: '"$SANDBOX"'/\(.)"' <<< "$REP"
    jq -r '.log_lines[]? | "    \(.)"' <<< "$REP"
    echo
    jq -r '"Notes: \(.notes)"' <<< "$REP"
} > "$RUN/report.md"
cat "$RUN/report.md"
echo
echo "report: $RUN/report.md"

jq -nc --arg date "$(date -Iseconds)" --arg title "$TITLE" --arg profile "$PROFILE_NAME" --arg target "$UI_TARGET" \
    --arg verdict "$VERDICT" --argjson deviations "$DEVIATIONS" --arg engine "$ENGINE" --arg model "$MODEL" --arg mode "$MODE" \
    --argjson cost "$COST" --argjson turns "$TURNS" --argjson calls "$CALLS" --argjson shots "$SHOTS" \
    --argjson wall "$WALL" --arg report "$RUN/report.md" \
    '{date:$date, title:$title, profile:$profile, target:$target, mode:$mode, engine:$engine, model:$model, verdict:$verdict, deviations:$deviations,
      cost_usd:$cost, turns:$turns, calls:$calls, shots:$shots, wall_s:$wall, report:$report}' >> "$STATE/e2e-runs.jsonl"
echo "cumulative E2E cost ($STATE/e2e-runs.jsonl): \$$(jq -s 'map(.cost_usd) | add | . * 10000 | round / 10000' "$STATE/e2e-runs.jsonl") over $(wc -l < "$STATE/e2e-runs.jsonl") runs"

[ "$VERDICT" = PASS ]

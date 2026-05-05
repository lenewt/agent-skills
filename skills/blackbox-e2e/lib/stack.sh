# shellcheck shell=bash
# Helpers for blackbox-e2e profiles, sourced by the runner and by `e2e` before the
# profile. Process helpers keep their state in $E2E_PRIV (pids, *.out, log offsets).

# uidrive (ui-drive skill): $UIDRIVE, else next to this skill in the same repo (resolved through
# the install symlinks, so it works whichever tools the skills are linked into), else installed or on PATH.
if [ -z "${UIDRIVE:-}" ]; then
    for UIDRIVE in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../ui-drive/bin/uidrive" \
                   "$HOME/.claude/skills/ui-drive/bin/uidrive" "$HOME/.copilot/skills/ui-drive/bin/uidrive" \
                   "$(command -v uidrive 2> /dev/null || true)"; do
        [ -x "$UIDRIVE" ] && break
    done
fi

die() { echo "e2e: $*" >&2; exit 1; }                 # a verb failed (tester sees it)
blocked() { echo "E2E: BLOCKED ($*)"; exit 3; }       # the run cannot be carried out (runner)

# --- remote or local commands ------------------------------------------------------
# rsh HOST CMD: run a shell command on HOST ("local" = here). ssh -n: callers loop over stdin.
rsh() {
    local host=$1; shift
    if [ "$host" = local ]; then bash -c "$*"
    else ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$host" "$@"; fi
}

# --- processes (each in its own process group) ---------------------------------------
# spawn NAME CWD CMD...: output to $E2E_PRIV/NAME.out. 8>&-: the e2e verb lock must not
# be inherited by long-running processes, or every later verb would block on it.
spawn() {
    local name=$1 cwd=$2; shift 2
    (cd "$cwd" && exec setsid nohup "$@" > "$E2E_PRIV/$name.out" 2>&1 < /dev/null 8>&-) &
    echo "$name $!" >> "$E2E_PRIV/pids"
}
wait_for() {  # wait_for FILE REGEX SECONDS
    local i
    for (( i = 0; i < $3; i++ )); do grep -qE "$2" "$1" 2>/dev/null && return 0; sleep 1; done
    return 1
}
group_pid() { awk -v n="$1" '$1 == n { p = $2 } END { print p }' "$E2E_PRIV/pids" 2>/dev/null; }
group_alive() { local p; p=$(group_pid "$1"); [ -n "$p" ] && kill -0 -- "-$p" 2>/dev/null; }
kill_group() {  # kill_group NAME
    local pid
    pid=$(group_pid "$1")
    [ -n "$pid" ] || return 0
    kill -TERM -- "-$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pid" 2>/dev/null || break; sleep 0.5; done
    kill -KILL -- "-$pid" 2>/dev/null
    awk -v n="$1" '$1 != n' "$E2E_PRIV/pids" > "$E2E_PRIV/pids.tmp" 2>/dev/null
    mv -f "$E2E_PRIV/pids.tmp" "$E2E_PRIV/pids"
}
kill_all_groups() {  # newest first
    local name
    [ -s "$E2E_PRIV/pids" ] || return 0
    for name in $(awk '{ print $1 }' "$E2E_PRIV/pids" | tac); do kill_group "$name"; done
    rm -f "$E2E_PRIV/pids"
}
groups_status() {
    local name pid
    [ -s "$E2E_PRIV/pids" ] || { echo "not started"; return; }
    while read -r name pid; do
        if kill -0 -- "-$pid" 2>/dev/null; then echo "$name: up"; else echo "$name: DOWN"; fi
    done < "$E2E_PRIV/pids"
}
groups_started() { [ -s "$E2E_PRIV/pids" ]; }
port_busy() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

# xvfb_start DISPLAY WIDTH HEIGHT: refuses a display that is already in use.
xvfb_start() {
    [ -e "/tmp/.X11-unix/X${1#:}" ] && die "display $1 busy. Report BLOCKED."
    spawn xvfb / Xvfb "$1" -screen 0 "${2}x${3}x24"
    local i
    for (( i = 0; i < 20; i++ )); do [ -e "/tmp/.X11-unix/X${1#:}" ] && return 0; sleep 0.25; done
    die "Xvfb $1 did not start. Report BLOCKED."
}

# ui_geom: set SCREEN_W/SCREEN_H from the UI target (remote devices).
# shellcheck disable=SC2034  # SCREEN_W/SCREEN_H are read by the runner and e2e
ui_geom() {
    if [ "$UI_TARGET" = local ]; then read -r SCREEN_W SCREEN_H < <("$UIDRIVE" -d "$UI_DISPLAY" geom)
    else read -r SCREEN_W SCREEN_H < <("$UIDRIVE" -t "$UI_TARGET" geom); fi
}

# --- SQLite on HOST ("local" or user@host) --------------------------------------------
sqlite_backup()  { rsh "$1" "sqlite3 '$2' \".backup '$3'\""; }    # HOST DB BAK
sqlite_restore() { rsh "$1" "sqlite3 '$2' \".restore '$3'\" && rm -f '$3'"; }
sqlite_apply() {  # HOST DB SQLFILE
    if [ "$1" = local ]; then sqlite3 -bail "$2" < "$3"
    else ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" "sqlite3 -bail '$2'" < "$3"; fi
}

# --- logs ---------------------------------------------------------------------------------
# Record each log's size at start, so `e2e log` only reads lines written during the run.
record_log_offsets() {
    local f
    : > "$E2E_PRIV/log-offsets"
    for f in "${LOG_FILES[@]}"; do
        echo "$f $(rsh "$LOG_HOST" "stat -c %s '$f' 2>/dev/null || echo 0")" >> "$E2E_PRIV/log-offsets"
    done
}
# log_delta FILE OFFSET: the file from OFFSET; a file shorter than OFFSET was rotated, read whole.
log_delta() {
    rsh "$LOG_HOST" "o=$2; s=\$(stat -c %s '$1' 2>/dev/null || echo 0); [ \$s -ge \$o ] || o=0; tail -c +\$((o + 1)) '$1' 2>/dev/null"
}

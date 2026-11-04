# shellcheck shell=bash
# Helpers for blackbox-e2e profiles, sourced by the runner and by `e2e` before the
# profile. Process helpers keep their state in $E2E_PRIV (pids, *.out, log offsets).

# uidrive (ui-drive skill): $UIDRIVE, else next to this skill in the same repo (resolved through
# the install symlinks, so it works whichever tools the skills are linked into), else on PATH.
if [ -z "${UIDRIVE:-}" ]; then
    for UIDRIVE in "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../ui-drive/bin/uidrive" \
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
# Record each log's size at start, so `e2e log` only reads lines written during the run, plus a
# checksum of its first 256 bytes: a file that profile_start removes and recreates can have the
# same size and the same inode, but not the same head.
record_log_offsets() {
    local f
    : > "$E2E_PRIV/log-offsets"
    for f in "${LOG_FILES[@]}"; do
        echo "$f $(rsh "$LOG_HOST" "s=\$(stat -c %s '$f' 2>/dev/null || echo 0); echo \$s \$(head -c 256 '$f' 2>/dev/null | cksum | cut -d' ' -f1)")" >> "$E2E_PRIV/log-offsets"
    done
}
# log_delta FILE OFFSET [HEADSUM]: the file from OFFSET; a file shorter than OFFSET, or whose head
# changed (rotated or recreated), is read whole.
log_delta() {
    rsh "$LOG_HOST" "o=$2; s=\$(stat -c %s '$1' 2>/dev/null || echo 0); n=\$o; [ \$n -le 256 ] || n=256
c=\$(head -c \$n '$1' 2>/dev/null | cksum | cut -d' ' -f1); [ \$s -ge \$o ] && [ \"\$c\" = \"${3:-\$c}\" ] || o=0
tail -c +\$((o + 1)) '$1' 2>/dev/null"
}

# --- puppet points (instrument-e2e: ../instrument-e2e/references/protocol.md) --------------
# puppet_send HOST SOCK LINE: one request to the product's puppet socket on HOST ("local" or
# user@host), prints the one-line reply; 0 iff it is `ok[ data]`. LINE goes through stdin, so
# quotes and spaces survive ssh; the client is socat, nc -U or python3, whichever HOST has.
# The reply may take up to 30 s (handlers are capped at 25 s); the client is killed after 35 s.
# 8>&-: the client must not hold the e2e verb lock.
puppet_send() {
    local host=$1 sock=$2 line=$3 q="'" cmd reply rc
    # POSIX sh (the target may only have busybox ash); SOCK single-quoted. nc only when it can
    # half-close (-N, or -q on Debian's), else the server never sees the end of the request.
    cmd="s='${sock//$q/$q\\$q$q}'
case \$s in *[!A-Za-z0-9_./-]*) x=1 ;; *) x=0 ;; esac  # socat parses quotes, : and , in addresses
h=\$(nc -h 2>&1) || true
if [ \$x = 0 ] && command -v socat > /dev/null 2>&1; then exec socat -t30 -T30 - UNIX-CONNECT:\"\$s\"
elif command -v nc > /dev/null 2>&1 && printf '%s' \"\$h\" | grep -qE -- '[[:space:]]-U' \\
        && printf '%s' \"\$h\" | grep -qE -- '[[:space:]]-N'; then exec nc -U -N -w30 \"\$s\"
elif command -v nc > /dev/null 2>&1 && printf '%s' \"\$h\" | grep -qE -- '[[:space:]]-U' \\
        && printf '%s' \"\$h\" | grep -qE -- '[[:space:]]-q'; then exec nc -U -q30 -w30 \"\$s\"
elif command -v python3 > /dev/null 2>&1; then exec python3 -c 'import socket, sys
c = socket.socket(socket.AF_UNIX); c.settimeout(30); c.connect(sys.argv[1])
c.sendall(sys.stdin.buffer.read()); c.shutdown(socket.SHUT_WR); b = b\"\"
while b\"\\n\" not in b:
    d = c.recv(4096)
    if not d: break
    b += d
sys.stdout.write(b.decode(\"utf-8\", \"replace\"))' \"\$s\"
else exit 97; fi"
    rc=0
    if [ "$host" = local ]; then reply=$(timeout 35 bash -c "$cmd" <<< "$line" 8>&-) || rc=$?
    else reply=$(timeout 35 ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "$cmd" <<< "$line" 8>&-) || rc=$?; fi
    [ "$rc" != 97 ] || die "puppet: no socat, nc -U or python3 on $host"
    [ "$rc" != 124 ] || echo "e2e: puppet: no reply within 35 s" >&2
    reply=${reply%%$'\n'*}; reply=${reply%$'\r'}
    [ -z "$reply" ] || printf '%s\n' "$reply"
    [[ "$reply" =~ ^ok( |$) ]]
}
# puppet_action NAME FILE: send each line of an @action block to $PUPPET_SOCK on $PUPPET_HOST
# (default local); blank lines, `#` and `--` comments are skipped; the first non-ok reply dies.
# Wire it with `profile_action() { puppet_action "$@"; }`.
puppet_action() {
    local line reply
    [ -n "${PUPPET_SOCK:-}" ] || die "puppet: PUPPET_SOCK is not set in the profile"
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
        if [ -z "$line" ] || [[ "$line" == \#* ]] || [[ "$line" == --* ]]; then continue; fi
        reply=$(puppet_send "${PUPPET_HOST:-local}" "$PUPPET_SOCK" "$line") || die "puppet: $line -> ${reply:-no reply}"
        printf '%s\n' "$reply"
    done < "$2"
}

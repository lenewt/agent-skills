# shellcheck shell=bash disable=SC2034  # profile contract variables are read by the runner and e2e
# blackbox-e2e profile: any local X11 application, started under its own Xvfb.
#   --set cmd="xcalc"            command line (required; run with bash -c, cwd below)
#   --set desc="a calculator"    one-line product description for the tester
#   --set cwd=DIR  size=1024x768  display=:97  settle=3   (defaults shown)
#   --set log="/path/a.log /path/b.log"  extra log files (the app's stdout/stderr is always one)
#   --set db=/path/app.sqlite     enables SQL fixtures on that SQLite file
# Copy this file to write a project profile: keep the top level to assignments and
# function definitions; product logic goes in the hooks.

PRODUCT_DESC=${E2E_SET_desc:-a desktop application}
REAL_DEVICE=0
UI_TARGET=local UI_DISPLAY=${E2E_SET_display:-:97}
SIZE=${E2E_SET_size:-1024x768}
SCREEN_W=${SIZE%x*} SCREEN_H=${SIZE#*x}
LOG_HOST=local
PROFILE_VARS=(APP_CWD)

profile_setup() {
    [ -n "${E2E_SET_cmd:-}" ] || blocked "x11-command needs --set cmd=\"<command line>\""
    command -v "${E2E_SET_cmd%% *}" > /dev/null || blocked "command not found: ${E2E_SET_cmd%% *}"
    APP_CWD=${E2E_SET_cwd:-$PWD}
    # shellcheck disable=SC2206  # space-separated list on purpose
    LOG_FILES=("$E2E_PRIV/app.out" ${E2E_SET_log:-})
}

profile_start() {
    groups_started && die "already started by this run (use stop first)"
    xvfb_start "$UI_DISPLAY" "$SCREEN_W" "$SCREEN_H"
    spawn app "$APP_CWD" env DISPLAY="$UI_DISPLAY" bash -c "$E2E_SET_cmd"
    sleep "${E2E_SET_settle:-3}"
    group_alive app || die "the application exited at start (BLOCKED)"
    echo "started on $UI_DISPLAY (${SCREEN_W}x${SCREEN_H})"
}
profile_stop()   { kill_all_groups; echo "stopped"; }
profile_status() { groups_status; }

if [ -n "${E2E_SET_db:-}" ]; then
    profile_db_backup()  { sqlite_backup local "$E2E_SET_db" "$E2E_PRIV/db.bak"; }
    profile_db_restore() { sqlite_restore local "$E2E_SET_db" "$E2E_PRIV/db.bak"; }
    profile_fixture() {  # FILE pre|live: live restarts the app so it reloads its data
        sqlite_apply local "$E2E_SET_db" "$1" || return 1
        if [ "$2" = live ] && group_alive app; then
            kill_group app
            spawn app "$APP_CWD" env DISPLAY="$UI_DISPLAY" bash -c "$E2E_SET_cmd"
            sleep "${E2E_SET_settle:-3}"
        fi
    }
fi

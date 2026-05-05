# shellcheck shell=bash disable=SC2034  # profile contract variables are read by the runner and e2e
# blackbox-e2e profile: a remote device whose GUI runs on X11 under a systemd unit.
#   --host root@10.0.0.5          (required) key-based ssh; the device needs xdotool + ffmpeg (ui-drive)
#   --set unit=myapp.service      (required) restarted by `e2e start`
#   --set desc="a kiosk UI"       one-line product description for the tester
#   --set log="/var/log/app.log"  log files on the device (space-separated)
#   --set db=/data/app.sqlite     enables SQL fixtures (the unit is stopped while the DB changes)
#   --set boot=30                 seconds to wait after a restart
#   --set real=0                  the device is a simulator (default 1: taps have physical effects)

DEVICE=${E2E_HOST:-}
PRODUCT_DESC=${E2E_SET_desc:-a device user interface}
REAL_DEVICE=${E2E_SET_real:-1}
UI_TARGET=${DEVICE:-unset} UI_DISPLAY=:0
LOG_HOST=${DEVICE:-unset}
# shellcheck disable=SC2206  # space-separated list on purpose
LOG_FILES=(${E2E_SET_log:-})
PROFILE_VARS=(DEVICE)

profile_setup() {
    [ -n "$DEVICE" ] || blocked "ssh-x11-systemd needs --host USER@HOST"
    [ -n "${E2E_SET_unit:-}" ] || blocked "ssh-x11-systemd needs --set unit=<systemd unit>"
    rsh "$DEVICE" true || blocked "$DEVICE unreachable"
    ui_geom
}

profile_start() {
    rsh "$DEVICE" "systemctl restart '$E2E_SET_unit'" || die "restart of $E2E_SET_unit failed (BLOCKED)"
    sleep "${E2E_SET_boot:-30}"
    profile_status
}
profile_stop()   { echo "the device stays up; the runner restores its data"; }
profile_status() { echo "$E2E_SET_unit: $(rsh "$DEVICE" "systemctl is-active '$E2E_SET_unit'")"; }

if [ -n "${E2E_SET_db:-}" ]; then
    profile_db_backup() { sqlite_backup "$DEVICE" "$E2E_SET_db" "$E2E_SET_db.e2e-bak"; }
    profile_db_restore() {
        rsh "$DEVICE" "systemctl stop '$E2E_SET_unit'" && sqlite_restore "$DEVICE" "$E2E_SET_db" "$E2E_SET_db.e2e-bak"
        local rc=$?
        rsh "$DEVICE" "systemctl start '$E2E_SET_unit'"
        return $rc
    }
    profile_fixture() {  # FILE pre|live
        rsh "$DEVICE" "systemctl stop '$E2E_SET_unit'" || return 1
        sqlite_apply "$DEVICE" "$E2E_SET_db" "$1"
        local rc=$?
        rsh "$DEVICE" "systemctl start '$E2E_SET_unit'"
        [ "$2" = live ] && sleep "${E2E_SET_boot:-30}"
        return $rc
    }
fi

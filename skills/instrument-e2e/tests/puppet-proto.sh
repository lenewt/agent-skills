#!/usr/bin/env bash
# Protocol test for the instrument-e2e snippets (Python, Node, Qt compile check) through puppet_send.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNIP=$HERE/../snippets
TMP=$(mktemp -d)
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

export E2E_PRIV=$TMP/priv; mkdir -p "$E2E_PRIV"
# shellcheck source=/dev/null
. "$HERE/../../blackbox-e2e/lib/stack.sh"
declare -F puppet_send > /dev/null || { echo "FAIL: puppet_send missing from blackbox-e2e/lib/stack.sh"; exit 2; }

fails=0 total=0
check() {  # check NAME CMD...: passes when CMD succeeds
    local name=$1; shift
    total=$((total + 1))
    if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}
eq() { [ "$1" = "$2" ]; }
# shellcheck disable=SC2053  # glob on the right is intended
match() { [[ $1 == $2 ]]; }

quiet() { [ ! -e "$1" ] && ! grep -q puppet-listening "$2"; }
wait_sock() { for _ in $(seq 50); do [ -S "$1" ] && return 0; sleep 0.1; done; return 1; }

test_lang() {  # test_lang NAME CMD...   (CMD starts the demo server; env E2E_PUPPET/E2E_TRACE set here)
    local name=$1; shift
    local sock=$TMP/$name.sock log=$TMP/$name.log reply
    E2E_PUPPET=$sock E2E_TRACE=1 "$@" > "$log" 2>&1 &
    PIDS+=($!)
    if ! wait_sock "$sock"; then check "$name: socket appears" false; cat "$log"; return; fi
    check "$name: socket appears" true

    reply=$(puppet_send local "$sock" help) || true
    check "$name: help lists echo" match "$reply" 'ok *echo*'
    reply=$(puppet_send local "$sock" 'echo a "b c"') || true
    check "$name: echo a \"b c\" -> ok a b c" eq "$reply" "ok a b c"
    reply=$(puppet_send local "$sock" boom) && s=0 || s=$?
    check "$name: boom -> err, nonzero exit" match "$reply:$([ "$s" -ne 0 ] && echo nz)" 'err*:nz'
    reply=$(puppet_send local "$sock" nope) || true
    check "$name: unknown point" eq "$reply" "err unknown point nope"
    reply=$(puppet_send local "$sock" slow) || true
    check "$name: slow handler reply survives" eq "$reply" "ok done"
    sleep 0.2
    check "$name: trace line for echo" grep -q 'E2E puppet point=echo reply=ok' "$log"
    check "$name: E2E ready line" grep -q 'E2E ready' "$log"

    rm -f "$sock"
    E2E_PUPPET='' E2E_TRACE=1 "$@" > "$TMP/$name.off.log" 2>&1 &
    PIDS+=($!)
    sleep 0.5
    check "$name: nothing listens when E2E_PUPPET unset" quiet "$sock" "$TMP/$name.off.log"
}

# Python demo
cat > "$TMP/demo.py" <<PYEOF
import sys, time
sys.path.insert(0, "$SNIP/python")
import e2e_puppet as e2e
def boom(a): raise RuntimeError("kaboom")
e2e.add("echo", "ARGS", "echo the arguments", lambda a: " ".join(a))
e2e.add("boom", "", "always fails", boom)
e2e.add("slow", "", "answers after 1 s", lambda a: (time.sleep(1), "done")[1])
e2e.ready()
time.sleep(5)
PYEOF
if command -v python3 > /dev/null; then test_lang python python3 -I -B "$TMP/demo.py"; else echo "python: skipped (no python3)"; fi

# Node demo
cat > "$TMP/demo.js" <<JSEOF
const e2e = require("$SNIP/node/e2e-puppet.js");
e2e.add("echo", "ARGS", "echo the arguments", (a) => a.join(" "));
e2e.add("boom", "", "always fails", () => { throw new Error("kaboom"); });
e2e.add("slow", "", "answers after 1 s", () => new Promise((r) => setTimeout(() => r("done"), 1000)));
e2e.ready();
setTimeout(() => process.exit(0), 5000);
JSEOF
if command -v node > /dev/null; then test_lang node node "$TMP/demo.js"; else echo "node: skipped (no node)"; fi

# Qt: real app with an event loop, built with and without E2E_PUPPET
QTPFX=${CMAKE_PREFIX_PATH:-}
if [ -z "$QTPFX" ]; then
    if [ -d "$HOME/QtCreator/5.14.2/gcc_64" ]; then QTPFX=$HOME/QtCreator/5.14.2/gcc_64
    elif command -v qmake > /dev/null; then QTPFX=$(qmake -query QT_INSTALL_PREFIX 2> /dev/null || true); fi
fi
if command -v cmake > /dev/null && command -v c++ > /dev/null && [ -n "$QTPFX" ]; then
    mkdir -p "$TMP/qt"
    cp "$SNIP"/qt/E2ePuppet.* "$TMP/qt/"
    cat > "$TMP/qt/main.cpp" <<'QTEOF'
#include <QCoreApplication>
#include <QThread>
#include <QTimer>
#include <stdexcept>
#include "E2ePuppet.h"
int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    int a = 1, b = 2;
    QString c = QStringLiteral("x");
    E2E_ADD("echo", "ARGS", "echo the arguments", [a, b, c](const QStringList &args) { Q_UNUSED(a) Q_UNUSED(b) Q_UNUSED(c); return args.join(' '); });
    E2E_ADD("boom", "", "always fails", [](const QStringList &) -> QString { throw std::runtime_error("kaboom"); });
    E2E_ADD("slow", "", "answers after 1 s", [](const QStringList &) { QThread::msleep(1000); return QStringLiteral("done"); });
    E2E_START();
    E2E_TRACE("started", {{"n", 1}});
    E2E_READY();
    QTimer::singleShot(8000, &app, &QCoreApplication::quit);
    return app.exec();
}
QTEOF
    cat > "$TMP/qt/CMakeLists.txt" <<'QTEOF'
cmake_minimum_required(VERSION 3.16)
project(e2eqt CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt5 COMPONENTS Core REQUIRED)
set(QT_VERSION_MAJOR 5)
add_executable(app main.cpp)
option(E2E_PUPPET "" OFF)
target_include_directories(app PRIVATE .)
target_link_libraries(app PRIVATE Qt5::Core)
if(E2E_PUPPET)
    find_package(Qt${QT_VERSION_MAJOR} COMPONENTS Network REQUIRED)
    target_sources(app PRIVATE E2ePuppet.cpp E2ePuppet.h)
    target_compile_definitions(app PRIVATE E2E_PUPPET)
    target_link_libraries(app PRIVATE Qt${QT_VERSION_MAJOR}::Network)
endif()
QTEOF
    qtok=1
    for flag in OFF ON; do
        if bash -c "cmake -S '$TMP/qt' -B '$TMP/qt/b$flag' -DCMAKE_PREFIX_PATH='$QTPFX' -DE2E_PUPPET=$flag && cmake --build '$TMP/qt/b$flag'" > "$TMP/qt/build$flag.log" 2>&1
        then check "qt: builds with E2E_PUPPET=$flag" true
        else check "qt: builds with E2E_PUPPET=$flag" false; tail -20 "$TMP/qt/build$flag.log"; qtok=0; fi
    done
    if [ "$qtok" = 1 ]; then
        n=$(strings "$TMP/qt/bOFF/app" | grep -c E2E_PUPPET || true)
        check "qt: release binary has no E2E_PUPPET string" eq "$n" 0
        LD_LIBRARY_PATH=$QTPFX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} test_lang qt "$TMP/qt/bON/app"
    fi
else
    echo "qt: skipped (no cmake/Qt)"
fi

echo "puppet-proto: $((total - fails))/$total checks passed"
[ "$fails" -eq 0 ]

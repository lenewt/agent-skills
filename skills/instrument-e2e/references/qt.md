# Qt / C++ (Qt5 and Qt6)

Snippet: `snippets/qt/E2ePuppet.{h,cpp}`. Contract: `protocol.md`.

## Drop it in
1. Copy `E2ePuppet.h` and `E2ePuppet.cpp` into the product (e.g. `src/e2e/`).
2. Add `snippets/qt/CMakeLists.snippet.txt` to the app target: option `E2E_PUPPET` (default OFF), the compile
   definition `E2E_PUPPET`, the two sources and `Qt::Network`, all inside `if(E2E_PUPPET)`. The include
   directory for the header stays outside the `if`, so the OFF build finds it. The snippet reuses the app's
   `QT_VERSION_MAJOR`; it does not call `find_package(QT NAMES …)` itself.
3. Build the test variant: `cmake -S . -B build-e2e -DE2E_PUPPET=ON`. The release build never sets it.

The whole `.cpp` and the real part of the header sit inside `#ifdef E2E_PUPPET`. Without the flag the macros
`E2E_ADD`, `E2E_START`, `E2E_TRACE`, `E2E_READY` expand to `((void)0)`, so call sites need no `#ifdef`.
Arguments of a disabled `E2E_TRACE(...)` are not evaluated.

## Register points
After `QApplication` exists, before `exec()`:

```cpp
#include "E2ePuppet.h"
E2E_ADD("sensor", "VALUE", "set the sensor reading", [&](const QStringList &a) {
    if (a.isEmpty()) throw std::runtime_error("usage: sensor VALUE");
    machine->simulateSensor(a[0]);
    return QString();            // or data, returned as "ok <data>"
});
E2E_START();                      // listens only when env E2E_PUPPET=<socket> is set
```

Handlers run on the thread that created the `QCoreApplication` (the GUI thread), because the server lives there.
Do not move the server to a worker thread. A handler that throws replies `err <what()>`.
Points stimulate only: call the same slot a real input would call, return no verdict.

## Debug and hook lines
```cpp
E2E_TRACE("state", {{"from", "idle"}, {"to", "busy"}});   // E2E state from=idle to=busy
E2E_READY();                                                  // E2E ready
```
Lines use the logging category `e2e` at info level and need `E2E_TRACE=1`. Qt drops `qCInfo` when the filter
hides it and the default message handler prints to stderr. Check that the product's own handler (file logger,
journald) does not filter category `e2e`, and that the file is in the profile's `LOG_FILES`. If the product sets
`QT_LOGGING_RULES`, add `e2e.info=true`.

Qt's default message handler prefixes category lines with `e2e: `, so write log patterns unanchored
(`E2E ready`) or as `^.*E2E ready`, never `^E2E ready`.

Call `E2E_READY()` when the main window is shown and the model loaded, not at `main()` start.

## Release check
```bash
strings build-release/app | grep -c E2E_PUPPET     # must print 0
```
The string `E2E_PUPPET` appears only in the gated code (env lookup). A count above 0 means the flag leaked.

## Pitfalls
- Socket path: use a path the tester can reach. On the board give the service `RuntimeDirectory=myapp` and use `/run/myapp/e2e.sock`; keep the path under 100 bytes (`/tmp` can be tmpfs
  per-service with `PrivateTmp=`). The server sets mode 0600 (`UserAccessOption`), so the tester runs as the
  same user as the app.
- Stale socket: `start()` removes it first. A crashed run leaves the file, never a blocked listen.
- `QLocalServer` needs a running event loop. Calling `E2E_START()` before `QApplication` is constructed fails.
- Qt 5.10+ is required (`qEnvironmentVariable`). On older Qt replace it with `qgetenv`.
- The `E2E_TRACE` macro uses `##__VA_ARGS__` (GCC and Clang). With MSVC use `/Zc:preprocessor`.
- Only one reply line per request. Newlines in data are replaced by spaces.

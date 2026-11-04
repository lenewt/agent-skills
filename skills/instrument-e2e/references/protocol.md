# E2E points: the contract

Every snippet under `../snippets/` and every point a plan proposes implements this text. A profile relies on it
through `puppet_send`/`puppet_action` (blackbox-e2e `lib/stack.sh`) and `wait_for`.

Three kinds of point:

| Kind | Does | The test uses it through |
|---|---|---|
| debug | logs a fact the screen hides | a log pattern in the scenario (`e2e log NAME`) |
| hook | logs a sync signal (`E2E ready`, `E2E idle`) | `wait_for` in the profile, instead of a sleep |
| puppet | injects one input (sensor value, hardware event, failure, clock) | an `@action` block, via `profile_action` |

## Gating (mandatory)

- **Built** only with the build flag `E2E_PUPPET`. C/C++/Qt: CMake option `-DE2E_PUPPET=ON`, which defines
  `E2E_PUPPET`; every point sits under `#ifdef E2E_PUPPET` or compiles to nothing without it. Node/Python: the
  module is required/imported only when env `E2E_PUPPET` is set, and the file is excluded from release packaging.
- **Active** only when env `E2E_PUPPET=<socket path>` is set. Unset: no socket, no thread, no output.
- **Release check**: `strings BINARY | grep -c E2E_PUPPET` must print 0; a release package has no `e2e-puppet`
  (or `e2e_puppet`) file. Put the check in the release pipeline.

## Puppet transport

- A Unix stream socket at `$E2E_PUPPET`. At start the product unlinks a stale socket there, then listens with mode
  0600. Keep the path under 100 bytes (the limit is 107) in a directory the app's user owns: `/run/myapp/e2e.sock`
  with systemd `RuntimeDirectory=myapp`, `$XDG_RUNTIME_DIR/myapp-e2e.sock`, or `/tmp/myapp-e2e.sock` locally.
- Each connection: read lines. Per request line `<point> [args…]` (split on whitespace; an arg may be single- or
  double-quoted), reply exactly one line: `ok[ data]` or `err <reason>`. The connection stays open for more lines
  until the client closes it.
- Unknown point: `err unknown point NAME`.
- Built-in `help`: `ok ` followed by `name args - description` entries joined by ` | ` (`name - description` for a
  point without arguments).
- GUI handlers must be dispatched to the main/UI thread (Qt: queued to the GUI thread; Node: the main process;
  Python: `on_loop`), so a point changes state exactly as a real input would.
- Timeouts: a handler returns within 25 s, and `puppet_send` waits up to 30 s for the reply, then kills its client
  at 35 s. Only the Python `on_loop` enforces the 25 s (past it the reply is an `err`). Qt handlers run
  synchronously on the GUI thread, and a Node handler that awaits another process must cap that wait itself.

```
> help
< ok sensor VALUE - set the sensor reading (0-100) | switch on|off - set the switch | reset - clear the inputs
> sensor 42
< ok
> sensor high
< err not a number: high
> calibrate
< err unknown point calibrate
```

## Debug lines

- Format: `E2E <event>[ key=value…]`. Values contain no spaces, or are double-quoted. One line per event.
- Written through the product's existing logger, to a file listed in the profile's `LOG_FILES`. Qt: logging
  category `e2e`. Other stacks: a logger or prefix named `e2e`.
- Enabled when env `E2E_TRACE=1`. Every puppet request also logs `E2E puppet point=NAME reply=ok|err`.
- **Facts only**: what happened, with its values (`E2E sensor-changed value=42`). Never PASS, FAIL, OK/KO or
  any word that grades the product; `e2e-lint.sh` refuses log patterns that match such words.

## Hooks

- `E2E ready` once, when the UI accepts input. Optional `E2E idle` when the app returns to rest (no pending
  timers or animations).
- Profiles wait on it instead of sleeping: `wait_for LOGFILE 'E2E ready' SECONDS`. Leave the regex unanchored: the
  logger adds its own prefix (Qt writes `e2e: E2E ready`).
- A state reset on start (clear a cache, a counter, a lock file) is a hook too: it runs before `E2E ready`.

## Points stimulate only

A point changes the input; it never checks the product, never returns a verdict, and never logs one. The tester
judges the screen and the product's own logs (blackbox-e2e: "stimulate, never judge"). A reply's data is a fact
(`ok queued`, `ok value=42`), not an assessment.

## Profile wiring

```bash
# Profile variables: the puppet socket and the host it lives on ("local" or user@host).
PUPPET_HOST=${E2E_HOST:-local}   PUPPET_SOCK=/tmp/myapp-e2e.sock
LOG_FILES=(/tmp/myapp.log)          # holds the E2E debug lines
profile_start() {
    groups_started && return 0
    rm -f /tmp/myapp.log
    E2E_PUPPET=$PUPPET_SOCK E2E_TRACE=1 spawn app / ./myapp --log /tmp/myapp.log
    wait_for /tmp/myapp.log 'E2E ready' 30 || die "app not ready. Report BLOCKED."
}
profile_action() { puppet_action "$@"; }   # each line of an @action block is one puppet request
```

Remote device (systemd): `PUPPET_HOST` is then `$E2E_HOST`. Give the unit a drop-in (see `shell-systemd.md`) with
`RuntimeDirectory=myapp` and `Environment=E2E_PUPPET=/run/myapp/e2e.sock E2E_TRACE=1`, and wait on the journal or
the log file with `rsh`.

Fixtures file (`-- @action` blocks; the tester applies them with `e2e fixture NAME`):

```sql
-- @action sensor-42
sensor 42
-- @action switch-on
switch on
```

Scenario log pattern on a debug line: `- sensor-seen: E2E sensor-changed value=42`.

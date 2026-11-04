# Python (Tk, Qt, GTK, headless)

Snippet: `snippets/python/e2e_puppet.py` (standard library only). Contract: `protocol.md`.

## Drop it in
1. Copy `e2e_puppet.py` into the package or next to the entry script.
2. Import it only when the env var is set:

```python
import os
e2e = None
if os.environ.get("E2E_PUPPET"):
    import e2e_puppet as e2e
```
3. Exclude the file from wheels and release archives (`MANIFEST.in`: `exclude e2e_puppet.py`; or a deb/rpm
   file list that omits it). The import starts the server thread.

## Register points
```python
if e2e:
    e2e.call_soon = e2e.on_loop(lambda f: root.after(0, f))      # Tk; see the module docstring for Qt
    e2e.add("sensor", "VALUE", "set the sensor reading", lambda a: machine.simulate_sensor(a[0]))
```
Handlers receive the argument list (`shlex` split, so `"b c"` is one argument) and return optional data.
An exception replies `err <message>`.

## Threading
The server runs in a daemon thread. UI toolkits are not thread safe, so handlers that touch widgets must run on
the UI thread. `call_soon` does that: `on_loop(schedule)` queues the call with the toolkit and waits (25 s) for
the result. The default `call_soon` calls the handler directly on the server thread. Use it only for non-GUI code
(headless daemons, handlers that only post to a queue). GUI apps must set `call_soon = on_loop(…)`. For asyncio use `loop.call_soon_threadsafe` inside `schedule`.
Do not block the UI thread in a handler.

## Debug and hook lines
```python
if e2e:
    e2e.trace("state", frm="idle", to="busy")   # E2E state frm=idle to=busy
    e2e.ready()                                     # E2E ready
```
Use keyword names that are valid Python (`from` is not). Lines need `E2E_TRACE=1` and go to the logger named
`e2e`. If the product configures `logging` with a file handler on the root logger, the lines land there.
With no logging configured they are printed to stdout. The file must be in the profile's `LOG_FILES`.

## Release check
```bash
unzip -l dist/app.whl | grep -c e2e_puppet        # 0
grep -rc E2E_PUPPET build/lib | grep -v ':0'       # only the gated import line, if any
```

## Pitfalls
- Socket path: `RuntimeDirectory=myapp` and `/run/myapp/e2e.sock` on the board, path under 100 bytes (`/tmp` may be private to the service). The socket is
  created under umask 0177 and chmod 0600.
- Stale socket: unlinked before bind. The socket file is not removed on exit; harmless.
- Import time: `start()` runs at import. Register points after the import; early requests get
  `err unknown point`, so call `e2e.ready()` after registering.
- Forking servers (gunicorn) start the thread in the parent only. Import after the fork.
- `print` to stdout is buffered when redirected; the snippet flushes, the product's own logging may not.

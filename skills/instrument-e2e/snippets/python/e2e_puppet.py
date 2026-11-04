"""E2E puppet and trace points (instrument-e2e). Standard library only.

Import it only in test builds, and leave it out of release packages:

    if os.environ.get("E2E_PUPPET"):
        import e2e_puppet as e2e

Registration API: add(name, args_spec, description, handler(args) -> optional data string)
                  trace(event, **fields);  ready()

The server runs in a thread. Handlers are dispatched through call_soon(fn), which must run fn on the
thread that owns the UI and return after it ran. Default: call fn directly on the server thread.

Tk:  e2e.call_soon = e2e.on_loop(lambda f: root.after(0, f))

Qt (PyQt/PySide): QTimer.singleShot does not work from this thread. Use a QObject living in the main thread
with a signal connected to a slot via Qt.QueuedConnection:
    class Bridge(QObject):
        call = Signal(object)
    bridge = Bridge(); bridge.call.connect(lambda f: f(), Qt.QueuedConnection)
    e2e.call_soon = e2e.on_loop(bridge.call.emit)
"""
import logging
import os
import shlex
import socketserver
import threading

log = logging.getLogger("e2e")
_points = {}
call_soon = lambda fn: fn()  # noqa: E731  default: direct call


def _trace_on():
    return os.environ.get("E2E_TRACE") == "1"


def _q(v):
    s = str(v)
    return '"' + s.replace('"', '\\"') + '"' if s == "" or any(c.isspace() or c == '"' for c in s) else s


def trace(event, **fields):
    """Log 'E2E <event> k=v ...' on the product logger (logger "e2e"; add a handler to your log file)."""
    if not _trace_on():
        return
    line = "E2E " + event + "".join(" %s=%s" % (k, _q(v)) for k, v in fields.items())
    if not logging.getLogger().handlers and not log.handlers:
        print(line, flush=True)  # no logging configured: stderr/stdout like a plain script
    else:
        log.info(line)


def ready():
    trace("ready")


def add(name, args_spec, description, handler):
    _points[name] = (args_spec, description, handler)


def on_loop(schedule):
    """Build a call_soon from schedule(fn) that queues fn on the UI loop (fn is called there)."""
    def call(fn):
        done, box = threading.Event(), {}

        def run():
            try:
                box["v"] = fn()
            except BaseException as e:  # noqa: BLE001  reported to the client as err
                box["e"] = e
            done.set()

        schedule(run)
        if not done.wait(25):
            raise RuntimeError("UI thread did not run the handler within 25s")
        if "e" in box:
            raise box["e"]
        return box["v"]
    return call


def dispatch(line):
    try:
        tok = shlex.split(line)
    except ValueError as e:
        return "err bad quoting: %s" % e
    if not tok:
        return "err empty request"
    name = tok[0]
    if name == "help":
        reply = "ok " + " | ".join("%s%s - %s" % (n, " " + a if a else "", d) for n, (a, d, _) in _points.items())
    elif name not in _points:
        reply = "err unknown point " + name
    else:
        try:
            data = call_soon(lambda: _points[name][2](tok[1:]))
            reply = "ok" if data in (None, "") else "ok %s" % data
        except Exception as e:  # noqa: BLE001
            reply = "err %s" % (e,)
    reply = reply.replace("\n", " ").replace("\r", " ")
    trace("puppet", point=name, reply="ok" if reply.startswith("ok") else "err")
    return reply


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        for raw in self.rfile:
            line = raw.decode("utf-8", "replace").strip()
            if line:
                self.wfile.write((dispatch(line) + "\n").encode())
                self.wfile.flush()


class _Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


_server = None


def start():
    """Listen on $E2E_PUPPET (mode 0600). No-op when it is unset. Returns the server or None."""
    global _server
    path = os.environ.get("E2E_PUPPET")
    if not path:
        return None
    try:
        os.unlink(path)  # stale socket
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        _server = _Server(path, _Handler)
    finally:
        os.umask(old)
    os.chmod(path, 0o600)
    threading.Thread(target=_server.serve_forever, name="e2e-puppet", daemon=True).start()
    trace("puppet-listening", socket=path)
    return _server


def stop():
    if _server:
        _server.shutdown()
        _server.server_close()


start()

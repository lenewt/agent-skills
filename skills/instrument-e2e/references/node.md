# Node

Snippet: `snippets/node/e2e-puppet.js` (no dependencies). Contract: `protocol.md`.

## Drop it in
1. Copy `e2e-puppet.js` next to the main process entry.
2. Require it only when the env var is set:

```js
const e2e = process.env.E2E_PUPPET ? require('./e2e-puppet') : null;
```
3. Keep it out of release packages: exclude `e2e-puppet.js` in your packager's file list
   (`.npmignore`, or a negation in the `files` allow-list).

The module starts the server on require, and only if `E2E_PUPPET` is a non-empty path. Gate every call site with
`e2e && …` (or `e2e?.add(…)`). A release build never loads the file, so nothing listens.

## Register points
```js
e2e?.add('sensor', 'VALUE', 'set the sensor reading', (args) => {
  if (!args.length) throw new Error('usage: sensor VALUE');
  machine.simulateSensor(args[0]);
  return 'queued';                    // optional data -> "ok queued". A Promise is awaited.
});
```
Handlers run on the main process event loop. Throwing (or rejecting) replies `err <message>`.

If the UI runs in another process, forward the stimulus over the app's existing IPC and answer with its reply
(an example is in the comments at the top of the snippet). Keep a timeout (25 s at most) on the round trip so a
dead UI process yields `err`, not a hung socket.

## Debug and hook lines
```js
e2e?.trace('state', { from: 'idle', to: 'busy' });   // E2E state from=idle to=busy
onUiReady(() => e2e?.ready());                                // E2E ready
```
Lines need `E2E_TRACE=1`. They go through `console.log` by default. If the product has its own logger
(winston, pino, a file), call `e2e.setLogger(line => logger.info(line))` once. The file must be in the
profile's `LOG_FILES`.

## Release check
```bash
find dist/ -name 'e2e-puppet*'                                   # nothing
npm pack --dry-run 2>&1 | grep -c e2e-puppet                     # 0
```
The gated `require('./e2e-puppet')` line may remain; the module file must be absent from the package.

## Pitfalls
- Socket path: on the board give the service `RuntimeDirectory=myapp` and use `/run/myapp/e2e.sock` (path under 100 bytes). Sandboxed services may not see `/tmp`.
  The snippet chmods the socket to 0600 after `listen`; the tester runs as the same user.
- Stale socket: unlinked before `listen`. If the directory does not exist, `listen` errors with
  `E2E puppet-error` in the log.
- Requests on one connection are answered in order; the reply to a slow handler delays the next one.
- Do not `console.log` PASS or FAIL words in handlers; the lint refuses them.
- Plain Node: call `e2e.stop()` on shutdown to close the server if the process stays alive for other reasons.

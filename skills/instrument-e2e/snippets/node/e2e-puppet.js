'use strict';
// E2E puppet and trace points (instrument-e2e), for Node.
// Load it only in test builds:
//   const e2e = process.env.E2E_PUPPET ? require('./e2e-puppet') : null;
// Exclude this file from release packaging (.npmignore, or "files": ["!**/e2e-puppet.js"]).
//
// Registration API: add(name, argsSpec, description, handler(args) -> optional data string)
//                   trace(event, {k: v});  ready();
//
// UI in another process: forward the stimulus over the app's existing IPC and resolve with its reply,
// capping the wait at 25 s so a dead UI process yields err:
//   e2e.add('click', 'SELECTOR', 'click a UI element', (args) =>
//     ui.request('click', args[0], { timeoutMs: 25000 }));

const net = require('net');
const fs = require('fs');

const points = new Map();
const traceOn = () => process.env.E2E_TRACE === '1';

function quote(v) {
  const s = String(v);
  return s === '' || /[\s"]/.test(s) ? '"' + s.replace(/"/g, '\\"') + '"' : s;
}

// Debug line "E2E <event> k=v ..." through the product logger (console.log by default).
let logger = (line) => console.log(line);
function setLogger(fn) { logger = fn; }

function trace(event, fields) {
  if (!traceOn()) return;
  let line = 'E2E ' + event;
  for (const [k, v] of Object.entries(fields || {})) line += ' ' + k + '=' + quote(v);
  logger(line);
}

function ready() { trace('ready'); }

function add(name, argsSpec, description, handler) {
  points.set(name, { argsSpec, description, handler });
}

// Whitespace split; single or double quotes group.
function split(line) {
  const out = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let m;
  while ((m = re.exec(line)) !== null) out.push(m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3]);
  return out;
}

async function dispatch(line) {
  const tok = split(line);
  if (tok.length === 0) return 'err empty request';
  const name = tok[0];
  let reply;
  if (name === 'help') {
    reply = 'ok ' + [...points].map(([n, p]) => `${n}${p.argsSpec ? ' ' + p.argsSpec : ''} - ${p.description}`).join(' | ');
  } else if (!points.has(name)) {
    reply = 'err unknown point ' + name;
  } else {
    try {
      const data = await points.get(name).handler(tok.slice(1));
      reply = data === undefined || data === null || data === '' ? 'ok' : 'ok ' + data;
    } catch (e) {
      reply = 'err ' + (e && e.message ? e.message : e);
    }
  }
  reply = reply.replace(/\r?\n/g, ' ');
  trace('puppet', { point: name, reply: reply.startsWith('ok') ? 'ok' : 'err' });
  return reply;
}

let server = null;
function start() {
  const path = process.env.E2E_PUPPET;
  if (!path) return null;
  try { fs.unlinkSync(path); } catch (_) { /* no stale socket */ }
  server = net.createServer({ allowHalfOpen: true }, (sock) => {
    let buf = '';
    let chain = Promise.resolve();
    sock.setEncoding('utf8');
    sock.on('data', (chunk) => {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (line) chain = chain.then(async () => { sock.write((await dispatch(line)) + '\n'); });
      }
    });
    // Client half-closed (sent its requests, waits for replies): answer all pending, then close.
    sock.on('end', () => { chain = chain.then(() => sock.end()); });
    sock.on('error', () => {});
  });
  server.listen(path, () => {
    try { fs.chmodSync(path, 0o600); } catch (_) { /* best effort */ }
    trace('puppet-listening', { socket: path });
  });
  server.on('error', (e) => logger('E2E puppet-error msg=' + quote(e.message)));
  return server;
}

function stop() { if (server) server.close(); }

// Starting on require keeps the call site to one line; E2E_PUPPET unset makes it a no-op.
start();

module.exports = { add, trace, ready, start, stop, setLogger, split };

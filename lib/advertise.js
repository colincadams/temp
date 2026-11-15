'use strict';
const fs = require('node:fs');
const path = require('node:path');
const childProcess = require('node:child_process');

const SERVICE_NAME = 'Brick Inventory';
const SERVICE_TYPE = '_brickinventory._tcp';

/** True for addresses only this computer can reach, where there is nobody to advertise to. */
function isLoopback(host) {
  const h = String(host || '').toLowerCase().replace(/^\[|\]$/g, '');
  return h === 'localhost' || h === '::1' || h.startsWith('127.') || h.startsWith('::ffff:127.');
}

/** Is `cmd` an executable somewhere on the PATH? */
function commandExists(cmd, env = process.env) {
  for (const dir of (env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    try { fs.accessSync(path.join(dir, cmd), fs.constants.X_OK); return true; } catch { /* keep looking */ }
  }
  return false;
}

/**
 * The command that announces the server as a Bonjour service on this platform, or null if there is none.
 * macOS ships dns-sd; Linux has avahi-publish when Avahi is installed.
 */
function advertiseCommand({ platform = process.platform, port, exists = commandExists, name = SERVICE_NAME }) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) return null;
  if (platform === 'darwin' && exists('dns-sd')) return { cmd: 'dns-sd', args: ['-R', name, SERVICE_TYPE, 'local', String(port)] };
  if (platform === 'linux' && exists('avahi-publish')) return { cmd: 'avahi-publish', args: ['-s', name, SERVICE_TYPE, String(port)] };
  return null;
}

/**
 * Announce the server on the local network so the phone app can find it. Never throws: if the address is
 * loopback, the command is missing or it fails, the server just runs unannounced. Logs one line either way.
 * Returns the child process, or null when nothing was started.
 */
function advertise({ host, port, log = () => {}, platform = process.platform, exists = commandExists, spawn = childProcess.spawn, settleMs = 1500 }) {
  if (isLoopback(host)) { log('Not advertised on the local network (listening on this computer only; start with HOST=0.0.0.0 so the phone app can find it)'); return null; }
  const byHand = `enter this computer's address and port ${port} in the phone app`;
  let command = null;
  try { command = advertiseCommand({ platform, port, exists }); } catch { /* treated as no command */ }
  if (!command) { log(`Not advertised on the local network (no Bonjour tool found; ${byHand})`); return null; }
  let said = false;
  const say = (msg) => { if (!said) { said = true; log(msg); } };
  const failed = (why) => say(`Not advertised on the local network (${command.cmd} ${why}; ${byHand})`);
  let child;
  try {
    child = spawn(command.cmd, command.args, { stdio: 'ignore' });
  } catch (err) {
    failed(`could not start: ${err.message}`);
    return null;
  }
  // Both tools keep running for as long as the service is announced, so one that is still alive after a moment is working.
  const up = setTimeout(() => say(`Advertised on the local network as "${SERVICE_NAME}" (${SERVICE_TYPE}, port ${port})`), settleMs);
  up.unref();
  child.on('error', (err) => { clearTimeout(up); failed(`could not start: ${err.message}`); });
  child.on('exit', (code, signal) => { clearTimeout(up); failed(`stopped${code ? ` with code ${code}` : signal ? ` on ${signal}` : ''}`); });
  process.once('exit', () => { try { child.kill(); } catch { /* already gone */ } });
  // A signal ends Node without running 'exit' handlers, so turn the usual ones into a normal exit.
  for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) process.once(sig, () => process.exit(code));
  return child;
}

module.exports = { advertise, advertiseCommand, commandExists, isLoopback, SERVICE_NAME, SERVICE_TYPE };

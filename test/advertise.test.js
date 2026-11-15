'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { advertise, advertiseCommand, commandExists, isLoopback } = require('../lib/advertise');

const yes = () => true, no = () => false;

test('picks dns-sd on a Mac and avahi-publish on Linux', () => {
  assert.deepEqual(advertiseCommand({ platform: 'darwin', port: 3000, exists: yes }),
    { cmd: 'dns-sd', args: ['-R', 'Brick Inventory', '_brickinventory._tcp', 'local', '3000'] });
  assert.deepEqual(advertiseCommand({ platform: 'linux', port: 8080, exists: yes }),
    { cmd: 'avahi-publish', args: ['-s', 'Brick Inventory', '_brickinventory._tcp', '8080'] });
});

test('has no command when the tool is missing, the platform is unknown or the port is not usable', () => {
  assert.equal(advertiseCommand({ platform: 'linux', port: 3000, exists: no }), null);
  assert.equal(advertiseCommand({ platform: 'darwin', port: 3000, exists: no }), null);
  assert.equal(advertiseCommand({ platform: 'win32', port: 3000, exists: yes }), null);
  assert.equal(advertiseCommand({ platform: 'darwin', port: 0, exists: yes }), null);
  assert.equal(advertiseCommand({ platform: 'darwin', port: NaN, exists: yes }), null);
  // Only the tool for this platform is looked for.
  const asked = [];
  advertiseCommand({ platform: 'linux', port: 3000, exists: (c) => { asked.push(c); return false; } });
  assert.deepEqual(asked, ['avahi-publish']);
});

test('knows a loopback address from one the network can reach', () => {
  for (const h of ['127.0.0.1', '127.1.2.3', 'localhost', 'LOCALHOST', '::1', '[::1]']) assert.equal(isLoopback(h), true, h);
  for (const h of ['0.0.0.0', '::', '192.168.1.20', 'my-mac.local']) assert.equal(isLoopback(h), false, h);
});

test('commandExists looks along the PATH', () => {
  assert.equal(commandExists('node', { PATH: require('node:path').dirname(process.execPath) }), true);
  assert.equal(commandExists('no-such-command-xyz'), false);
  assert.equal(commandExists('node', { PATH: '' }), false);
});

test('does not start anything on loopback or without a tool, and says so once', () => {
  const spawn = () => { throw new Error('must not spawn'); };
  let lines = [];
  assert.equal(advertise({ host: '127.0.0.1', port: 3000, log: (l) => lines.push(l), platform: 'darwin', exists: yes, spawn }), null);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Not advertised/);
  lines = [];
  assert.equal(advertise({ host: '0.0.0.0', port: 3000, log: (l) => lines.push(l), platform: 'linux', exists: no, spawn }), null);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Not advertised/);
});

// Stand-ins for a child process; process-wide exit hooks added by advertise() are removed again after each test.
function fakeChild() { const c = new EventEmitter(); c.killed = 0; c.kill = () => { c.killed++; }; return c; }
function withHooksRestored(fn) {
  const events = ['exit', 'SIGINT', 'SIGTERM', 'SIGHUP'];
  const before = new Map(events.map((e) => [e, process.listeners(e)]));
  return Promise.resolve().then(fn).finally(() => {
    for (const e of events) for (const l of process.listeners(e)) if (!before.get(e).includes(l)) process.removeListener(e, l);
  });
}

test('spawns the command, reports it once it stays up, and kills it on exit', () => withHooksRestored(async () => {
  const lines = [], calls = [], child = fakeChild();
  const spawn = (cmd, args) => { calls.push([cmd, args]); return child; };
  const exitHooks = process.listeners('exit').length;
  assert.equal(advertise({ host: '0.0.0.0', port: 3000, log: (l) => lines.push(l), platform: 'darwin', exists: yes, spawn, settleMs: 5 }), child);
  assert.deepEqual(calls, [['dns-sd', ['-R', 'Brick Inventory', '_brickinventory._tcp', 'local', '3000']]]);
  assert.deepEqual(lines, []);
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Advertised on the local network as "Brick Inventory"/);
  const added = process.listeners('exit').slice(exitHooks);
  assert.equal(added.length, 1);
  added[0]();
  assert.equal(child.killed, 1);
}));

test('a command that fails to start or stops straight away is reported, not thrown', () => withHooksRestored(async () => {
  let lines = [];
  const log = (l) => lines.push(l);
  const opts = { host: '0.0.0.0', port: 3000, log, platform: 'linux', exists: yes, settleMs: 5 };

  assert.equal(advertise({ ...opts, spawn: () => { throw new Error('EACCES'); } }), null);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Not advertised.*avahi-publish could not start: EACCES/);

  lines = [];
  const missing = fakeChild();
  advertise({ ...opts, spawn: () => missing });
  missing.emit('error', new Error('spawn avahi-publish ENOENT'));
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Not advertised.*ENOENT/);

  lines = [];
  const dies = fakeChild();
  advertise({ ...opts, spawn: () => dies });
  dies.emit('exit', 1, null); // e.g. the Avahi daemon is not running
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(lines.length, 1);
  assert.match(lines[0], /^Not advertised.*stopped with code 1/);
}));

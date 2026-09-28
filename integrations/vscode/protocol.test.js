'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const vm = require('node:vm');

test('private socket protocol rejects invalid requests and requires the pending window callback',
  { skip: process.platform !== 'darwin' }, async () => {
    const home = await fs.mkdtemp('/tmp/lv-');
    let handler, uri, serverSocket, focused = 0;
    const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode', asExternalUri: async value => value },
      Uri: { parse: text => { uri = new URL(text); return { toString: () => text }; } },
      window: { state: { focused: true }, registerUriHandler: value => { handler = value; return { dispose() {} }; }, terminals: [] } };
    const terminal = { processId: Promise.resolve(12345), show() { focused++; api.window.activeTerminal = terminal; } };
    api.window.terminals.push(terminal);
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    const localNet = { ...net, createServer: callback => net.createServer(socket => { serverSocket = socket; callback(socket); }) };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home, tmpdir: () => home } : name === 'node:net' ? localNet : require(name);
    vm.runInThisContext('(function(require,module){' + source + '\n})')(load, module);
    try {
      await module.exports.activate({ subscriptions: [] });
      const directory = path.join(home, 'Library/Application Support/Lunavect/IDEBridge');
      const [name] = await fs.readdir(directory);
      const descriptor = JSON.parse(await fs.readFile(path.join(directory, name), 'utf8'));
      assert.equal((await fs.stat(directory)).mode & 0o777, 0o700);
      assert.equal((await fs.stat(descriptor.socketPath)).mode & 0o777, 0o600);
      async function request(message, callback) {
        return new Promise((resolve, reject) => {
          const socket = net.connect(descriptor.socketPath); let buffer = '';
          socket.setTimeout(1000, () => { socket.destroy(); reject(Error('fixture timeout')); });
          socket.on('error', reject); socket.on('connect', () => socket.write(message));
          socket.on('data', async data => {
            buffer += data;
            const index = buffer.indexOf('\n'); if (index < 0) return;
            const reply = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
            if (reply.status === 'ready') { try { await callback(reply, socket); } catch (error) { socket.destroy(); reject(error); } }
            else { socket.end(); resolve(reply); }
          });
          socket.on('end', () => resolve(null));
          socket.on('close', () => resolve(null));
        });
      }
      const target = { kind: 'terminal', ancestors: [12345] };
      const message = action => JSON.stringify({ version: 1, action, target }) + '\n';
      assert.equal((await request(message('probe'))).status, 'matched');
      assert.equal(focused, 0);
      assert.equal((await request(JSON.stringify({ version: 1, action: 'execute', target }) + '\n')).status, 'unsupported');
      assert.equal(await request('x'.repeat(16385)), null);
      assert.equal((await request(message('open'), async () => {
        await handler.handleUri({ path: '/focus/00000000-0000-0000-0000-000000000000' });
        assert.equal(focused, 0, 'An unsolicited callback cannot focus a terminal');
        await handler.handleUri({ path: uri.pathname });
      })).status, 'focused');
      assert.equal(focused, 1);
      await handler.handleUri({ path: uri.pathname });
      assert.equal(focused, 1, 'Callbacks are single use');
      let callbackDone;
      const finished = new Promise(resolve => { callbackDone = resolve; });
      await request(message('open'), async (_, socket) => {
        let release;
        terminal.processId = new Promise(resolve => { release = resolve; });
        const opening = handler.handleUri({ path: uri.pathname });
        const closed = new Promise(resolve => serverSocket.once('close', resolve));
        socket.destroy(); await closed;
        release(12345); await opening;
        callbackDone();
      });
      await finished;
      assert.equal(focused, 1, 'A disconnected request must not focus after delayed discovery');
    } finally {
      await module.exports.deactivate();
      await fs.rm(home, { recursive: true, force: true });
    }
  });

for (const phase of ['startup', 'heartbeat']) {
test(`deactivation during ${phase} leaves no descriptor or timer behind`,
  { skip: process.platform !== 'darwin' }, async () => {
    const home = await fs.mkdtemp('/tmp/lv-');
    let heartbeat, unblock, publishing, held = false, intervals = 0;
    let markPublishing;
    const hasStarted = new Promise(resolve => { markPublishing = resolve; });
    const customFS = { ...fs, async writeFile(file, ...args) {
      if (held && String(file).endsWith('.tmp')) {
        markPublishing();
        await new Promise(resolve => { unblock = resolve; });
      }
      return fs.writeFile(file, ...args);
    } };
    const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode' },
      window: { registerUriHandler: () => ({ dispose() {} }), terminals: [] } };
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home, tmpdir: () => home } :
      name === 'node:fs/promises' ? customFS : require(name);
    vm.runInThisContext('(function(require,module,setInterval,clearInterval){' + source + '\n})')(
      load, module, callback => { heartbeat = callback; intervals++; return 1; }, handle => { if (handle !== undefined) intervals--; });
    try {
      held = phase === 'startup';
      const activating = module.exports.activate({ subscriptions: [] });
      if (phase === 'heartbeat') {
        await activating;
        held = true;
        publishing = heartbeat();
      }
      await hasStarted;
      const closing = module.exports.deactivate();
      // Force the ordering that used to republish a record after cleanup.
      await new Promise(resolve => setTimeout(resolve, 25));
      unblock();
      await Promise.all([closing, publishing, activating]);
      const directory = path.join(home, 'Library/Application Support/Lunavect/IDEBridge');
      assert.deepEqual(await fs.readdir(directory), []);
      assert.equal(intervals, 0);
    } finally {
      held = false; unblock?.();
      await module.exports.deactivate();
      await fs.rm(home, { recursive: true, force: true });
    }
  });

}

test('a slowly arriving incomplete request cannot keep a connection beyond its overall budget',
  { skip: process.platform !== 'darwin' }, async () => {
    const home = await fs.mkdtemp('/tmp/lv-');
    const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode' },
      window: { registerUriHandler: () => ({ dispose() {} }), terminals: [] } };
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    // Accelerate both inactivity and overall timers equally; real socket traffic
    // keeps resetting the former, and must never reset the latter.
    const scale = ms => ms === 10000 ? 100 : ms;
    const localNet = { ...net, createServer(callback) { return net.createServer(socket => {
      const idle = socket.setTimeout.bind(socket);
      socket.setTimeout = (ms, handler) => idle(scale(ms), handler);
      callback(socket);
    }); } };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home, tmpdir: () => home } :
      name === 'node:net' ? localNet : require(name);
    vm.runInThisContext('(function(require,module,setTimeout){' + source + '\n})')(
      load, module, (callback, ms) => setTimeout(callback, scale(ms)));
    let socket, trickle, watchdog;
    try {
      await module.exports.activate({ subscriptions: [] });
      const directory = path.join(home, 'Library/Application Support/Lunavect/IDEBridge');
      const [name] = await fs.readdir(directory);
      const descriptor = JSON.parse(await fs.readFile(path.join(directory, name), 'utf8'));
      const expired = await new Promise((resolve, reject) => {
        socket = net.connect(descriptor.socketPath);
        socket.on('error', error => {
          if (['EPIPE', 'ECONNRESET'].includes(error.code)) resolve(true);
          else reject(error);
        });
        socket.on('data', () => {});
        socket.on('close', () => resolve(true));
        socket.on('connect', () => {
          socket.write(' ');
          trickle = setInterval(() => socket.write(' '), 20);
          watchdog = setTimeout(() => { resolve(false); socket.destroy(); }, 600);
        });
      });
      assert.equal(expired, true, 'Trickle traffic must not extend a request forever');
    } finally {
      clearInterval(trickle); clearTimeout(watchdog); socket?.destroy();
      await module.exports.deactivate(); await fs.rm(home, { recursive: true, force: true });
    }
  });

// A short private temporary directory keeps socket paths within sockaddr_un and
// away from the real companion folders.
async function loadCompanion({ intervals } = {}) {
  const home = await fs.mkdtemp('/tmp/lv-');
  const warnings = [];
  const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode', asExternalUri: async value => value },
    Uri: { parse: text => ({ toString: () => text }) },
    window: { state: { focused: true }, registerUriHandler: () => ({ dispose() {} }), terminals: [{ processId: Promise.resolve(12345), show() {} }],
      showWarningMessage: async message => { warnings.push(message); } } };
  const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
  const module = { exports: {} };
  const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home, tmpdir: () => home } : require(name);
  const timers = intervals ?? { setInterval, clearInterval };
  vm.runInThisContext('(function(require,module,setInterval,clearInterval){' + source + '\n})')(load, module, timers.setInterval, timers.clearInterval);
  const cleanup = async () => { await module.exports.deactivate(); await fs.rm(home, { recursive: true, force: true }); };
  return { home, api, module, warnings, cleanup };
}
async function readDescriptor(home) {
  const directory = path.join(home, 'Library/Application Support/Lunavect/IDEBridge');
  const [name] = (await fs.readdir(directory)).filter(file => file.endsWith('.json'));
  return name ? JSON.parse(await fs.readFile(path.join(directory, name), 'utf8')) : undefined;
}
function probe(socketPath) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(socketPath); let buffer = '';
    socket.setTimeout(1000, () => { socket.destroy(); reject(Error('fixture timeout')); });
    socket.on('error', reject);
    socket.on('connect', () => socket.write(JSON.stringify({ version: 1, action: 'probe', target: { kind: 'terminal', ancestors: [12345] } }) + '\n'));
    socket.on('data', data => { buffer += data; if (buffer.includes('\n')) { socket.end(); resolve(JSON.parse(buffer.slice(0, buffer.indexOf('\n')))); } });
  });
}

test('the descriptor names the companion version and the socket stays in the private temporary directory (N-09, N-16)',
  { skip: process.platform !== 'darwin' }, async () => {
    const companion = await loadCompanion();
    try {
      await companion.module.exports.activate({ subscriptions: [] });
      const descriptor = await readDescriptor(companion.home);
      assert.equal(descriptor.version, 1, 'The descriptor protocol stays 1: the new field is optional');
      assert.equal(descriptor.companion, require('./package.json').version);
      assert.equal(path.dirname(descriptor.socketPath), path.join(companion.home, 'lunavect'));
      assert.equal((await fs.stat(path.dirname(descriptor.socketPath))).mode & 0o777, 0o700);
      assert.equal((await fs.stat(descriptor.socketPath)).mode & 0o777, 0o600);
      assert.ok(Buffer.byteLength(descriptor.socketPath) <= 103);
      assert.equal((await probe(descriptor.socketPath)).status, 'matched');
      assert.deepEqual(companion.warnings, []);
    } finally { await companion.cleanup(); }
  });

test('a heartbeat recreates a deleted socket directory and serves again (N-05)',
  { skip: process.platform !== 'darwin' }, async () => {
    let heartbeat;
    const companion = await loadCompanion({ intervals: { setInterval: callback => { heartbeat = callback; return 1; }, clearInterval: () => {} } });
    try {
      await companion.module.exports.activate({ subscriptions: [] });
      const descriptor = await readDescriptor(companion.home);
      // Never remove a directory outside this fixture (older code used the real /tmp folder).
      assert.ok(descriptor.socketPath.startsWith(companion.home + '/'), 'The socket must live in the fixture directory');
      await fs.rm(path.dirname(descriptor.socketPath), { recursive: true, force: true });
      await assert.rejects(probe(descriptor.socketPath));
      await heartbeat();
      assert.equal((await probe(descriptor.socketPath)).status, 'matched', 'The endpoint is back without reloading the window');
      assert.equal((await readDescriptor(companion.home)).socketPath, descriptor.socketPath);
    } finally { await companion.cleanup(); }
  });

test('an unsafe socket directory is reported in the editor instead of failing silently (N-16)',
  { skip: process.platform !== 'darwin' }, async () => {
    const companion = await loadCompanion();
    try {
      await fs.mkdir(path.join(companion.home, 'elsewhere'));
      await fs.symlink(path.join(companion.home, 'elsewhere'), path.join(companion.home, 'lunavect'));
      await companion.module.exports.activate({ subscriptions: [] });
      assert.equal(companion.warnings.length, 1);
      assert.match(companion.warnings[0], /Lunavect/);
      assert.equal(await readDescriptor(companion.home), undefined, 'No endpoint is advertised');
    } finally { await companion.cleanup(); }
  });

test('at most eight connections are served at once; a freed slot is reused (§4 item 13)',
  { skip: process.platform !== 'darwin' }, async () => {
    const companion = await loadCompanion();
    const held = [];
    try {
      await companion.module.exports.activate({ subscriptions: [] });
      const { socketPath } = await readDescriptor(companion.home);
      for (let index = 0; index < 8; index++) {
        const socket = net.connect(socketPath);
        await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
        socket.write(' '); // an unfinished request keeps the slot
        held.push(socket);
      }
      await new Promise(resolve => setTimeout(resolve, 50));
      const refused = await new Promise(resolve => {
        const socket = net.connect(socketPath);
        socket.on('error', () => resolve(true)); socket.on('close', () => resolve(true));
        socket.on('data', () => resolve(false));
        socket.on('connect', () => socket.write(JSON.stringify({ version: 1, action: 'probe', target: { kind: 'terminal', ancestors: [12345] } }) + '\n'));
      });
      assert.equal(refused, true, 'A ninth connection is closed without an answer');
      held.shift().destroy();
      await new Promise(resolve => setTimeout(resolve, 50));
      assert.equal((await probe(socketPath)).status, 'matched');
    } finally { for (const socket of held) socket.destroy(); await companion.cleanup(); }
  });

test('an editor built on VS Code reports its own bundle identifier from product.json',
  { skip: process.platform !== 'darwin' }, async () => {
    const home = await fs.mkdtemp('/tmp/lv-');
    const appRoot = path.join(home, 'Cursor.app/Contents/Resources/app');
    await fs.mkdir(appRoot, { recursive: true });
    await fs.writeFile(path.join(appRoot, 'product.json'), JSON.stringify({ darwinBundleIdentifier: 'com.todesktop.230313mzl4w4u92', urlProtocol: 'cursor' }));
    const api = { env: { appRoot, uriScheme: 'cursor' }, window: { registerUriHandler: () => ({ dispose() {} }), terminals: [] } };
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home, tmpdir: () => home } : require(name);
    vm.runInThisContext('(function(require,module){' + source + '\n})')(load, module);
    try {
      await module.exports.activate({ subscriptions: [] });
      const directory = path.join(home, 'Library/Application Support/Lunavect/IDEBridge');
      const [name] = await fs.readdir(directory);
      const descriptor = JSON.parse(await fs.readFile(path.join(directory, name), 'utf8'));
      assert.equal(descriptor.bundleIdentifier, 'com.todesktop.230313mzl4w4u92');
      assert.equal(descriptor.appPath, path.join(home, 'Cursor.app'));
    } finally {
      await module.exports.deactivate();
      await fs.rm(home, { recursive: true, force: true });
    }
  });

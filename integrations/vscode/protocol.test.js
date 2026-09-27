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
    const home = await fs.mkdtemp(path.join(os.tmpdir(), 'lunavect-protocol-'));
    let handler, uri, serverSocket, focused = 0;
    const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode', asExternalUri: async value => value },
      Uri: { parse: text => { uri = new URL(text); return { toString: () => text }; } },
      window: { state: { focused: true }, registerUriHandler: value => { handler = value; return { dispose() {} }; }, terminals: [] } };
    const terminal = { processId: Promise.resolve(12345), show() { focused++; api.window.activeTerminal = terminal; } };
    api.window.terminals.push(terminal);
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    const localNet = { ...net, createServer: callback => net.createServer(socket => { serverSocket = socket; callback(socket); }) };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home } : name === 'node:net' ? localNet : require(name);
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
    const home = await fs.mkdtemp(path.join(os.tmpdir(), 'lunavect-shutdown-'));
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
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home } :
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
    const home = await fs.mkdtemp(path.join(os.tmpdir(), 'lunavect-slow-peer-'));
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
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home } :
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

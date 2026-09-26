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
    let handler, uri, focused = 0;
    const api = { env: { appRoot: '/Applications/Visual Studio Code.app/Contents/Resources/app', uriScheme: 'vscode', asExternalUri: async value => value },
      Uri: { parse: text => { uri = new URL(text); return { toString: () => text }; } },
      window: { state: { focused: true }, registerUriHandler: value => { handler = value; return { dispose() {} }; }, terminals: [] } };
    const terminal = { processId: Promise.resolve(12345), show() { focused++; api.window.activeTerminal = terminal; } };
    api.window.terminals.push(terminal);
    const source = await fs.readFile(path.join(__dirname, 'extension.js'), 'utf8');
    const module = { exports: {} };
    const load = name => name === 'vscode' ? api : name === 'node:os' ? { ...os, homedir: () => home } : require(name);
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
            if (reply.status === 'ready') { try { await callback(reply); } catch (error) { socket.destroy(); reject(error); } }
            else { socket.end(); resolve(reply); }
          });
          socket.on('end', () => resolve(null));
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
    } finally {
      await module.exports.deactivate();
      await fs.rm(home, { recursive: true, force: true });
    }
  });

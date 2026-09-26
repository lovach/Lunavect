'use strict';

const vscode = require('vscode');
const fs = require('node:fs/promises');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { UUID, validateTarget, resolveTarget, focusTarget } = require('./routing');

const MAX_BYTES = 16384;
const TIMEOUT_MS = 10000;
let dispose;

async function privateDirectory(directory) {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Unsafe bridge directory');
  await fs.chmod(directory, 0o700);
}

async function activate(context) {
  if (process.platform !== 'darwin' || vscode.env.remoteName) return;
  const root = path.join(os.homedir(), 'Library/Application Support/Lunavect/IDEBridge');
  const sockets = '/tmp/lunavect-ide-' + process.getuid();
  await privateDirectory(root); await privateDirectory(sockets);
  const id = randomUUID();
  const socketPath = path.join(sockets, id + '.sock');
  const descriptorPath = path.join(root, id + '.json');
  const pending = new Map();
  const connections = new Set();
  const appPath = path.resolve(vscode.env.appRoot, '../../..');
  const descriptor = {
    version: 1, id, editor: 'vscode', pid: process.pid, appPath,
    bundleIdentifier: vscode.env.uriScheme === 'vscode-insiders' ? 'com.microsoft.VSCodeInsiders' : 'com.microsoft.VSCode',
    socketPath, updatedAt: Date.now() / 1000
  };
  const handler = vscode.window.registerUriHandler({
    async handleUri(uri) {
      const key = uri.path.replace(/^\/focus\//, '');
      if (!UUID.test(key)) return;
      const request = pending.get(key);
      if (!request) return;
      pending.delete(key);
      try { request.finish(await focusTarget(vscode, request.target)); }
      catch { request.finish({ status: 'failed' }); }
    }
  });
  const server = net.createServer(socket => {
    if (connections.size >= 8) { socket.destroy(); return; }
    connections.add(socket);
    let bytes = Buffer.alloc(0), handled = false;
    const send = value => { if (!socket.destroyed) socket.write(JSON.stringify(value) + '\n'); };
    const finish = value => { send(value); socket.end(); };
    socket.setTimeout(TIMEOUT_MS, () => { finish({ status: 'timeout' }); socket.destroy(); });
    socket.on('error', () => socket.destroy());
    socket.on('close', () => {
      connections.delete(socket);
      for (const [key, value] of pending) if (value.socket === socket) pending.delete(key);
    });
    socket.on('data', async chunk => {
      if (handled) return;
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length > MAX_BYTES) { socket.destroy(); return; }
      if (!bytes.includes(10)) return;
      handled = true;
      try {
        const request = JSON.parse(bytes.subarray(0, bytes.indexOf(10)).toString('utf8'));
        if (request.version !== 1 || !['probe', 'open'].includes(request.action) || !validateTarget(request.target)) {
          finish({ status: 'unsupported' }); return;
        }
        const match = await resolveTarget(vscode, request.target);
        if (socket.destroyed) return;
        if (match.status !== 'matched' || request.action === 'probe') {
          finish({ status: match.status, shellPID: match.shellPID }); return;
        }
        const key = randomUUID();
        pending.set(key, { socket, target: request.target, finish });
        // Resolve at click time and pass the result unchanged. VS Code routes the
        // callback to this exact window and brings it forward before our handler.
        const uri = await vscode.env.asExternalUri(vscode.Uri.parse(vscode.env.uriScheme + '://lovach.lunavect/focus/' + key));
        if (socket.destroyed) { pending.delete(key); return; }
        send({ status: 'ready', url: uri.toString() });
      } catch { finish({ status: 'failed' }); }
    });
  });
  let timer;
  dispose = async () => {
    clearInterval(timer); handler.dispose();
    for (const socket of connections) socket.destroy();
    server.close(); pending.clear();
    await Promise.all([descriptorPath, descriptorPath + '.tmp', socketPath].map(file => fs.unlink(file).catch(() => {})));
  };
  context.subscriptions.push({ dispose: () => { void dispose?.(); } });
  const publish = async () => {
    descriptor.updatedAt = Date.now() / 1000;
    const temporary = descriptorPath + '.tmp';
    await fs.writeFile(temporary, JSON.stringify(descriptor), { mode: 0o600 });
    await fs.rename(temporary, descriptorPath);
  };
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
    await fs.chmod(socketPath, 0o600);
    await publish();
    timer = setInterval(() => publish().catch(() => {}), 30000);
  } catch (error) { await dispose(); throw error; }
}

async function deactivate() { await dispose?.(); }
module.exports = { activate, deactivate };

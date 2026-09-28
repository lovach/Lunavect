'use strict';

const vscode = require('vscode');
const fs = require('node:fs/promises');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { UUID, validateTarget, resolveTarget, focusTarget } = require('./routing');
const { version } = require('./package.json');

const MAX_BYTES = 16384;
const TIMEOUT_MS = 10000;
// sockaddr_un holds 104 bytes including the terminator.
const MAX_SOCKET_PATH = 103;
let dispose;

async function privateDirectory(directory) {
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  const stat = await fs.lstat(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Unsafe bridge directory');
  await fs.chmod(directory, 0o700);
}

// The user's private temporary directory. Lunavect also accepts the shared
// /tmp folder of companions up to 0.1.1, used here only if the path is too long.
function socketDirectory(id) {
  const directory = path.join(os.tmpdir(), 'lunavect');
  if (Buffer.byteLength(path.join(directory, id + '.sock')) <= MAX_SOCKET_PATH) return directory;
  return '/tmp/lunavect-ide-' + process.getuid();
}

// The editor's own bundle identifier from its product.json: Cursor and other
// editors built on VS Code name theirs there. Companions up to 0.1.2 always
// reported VS Code's, which Lunavect rejected for any other editor.
async function bundleIdentifier(env, readFile = fs.readFile) {
  try {
    const product = JSON.parse(await readFile(path.join(env.appRoot, 'product.json'), 'utf8'));
    const identifier = product && product.darwinBundleIdentifier;
    if (typeof identifier === 'string' && /^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$/.test(identifier)) return identifier;
  } catch {}
  return env.uriScheme === 'vscode-insiders' ? 'com.microsoft.VSCodeInsiders' : 'com.microsoft.VSCode';
}

async function isSocket(file) {
  try { return (await fs.lstat(file)).isSocket(); } catch { return false; }
}

// A failed start used to be visible only in the extension host log.
function warn(error) {
  const reason = error && error.message === 'Unsafe bridge directory'
    ? 'its private folder is a link or belongs to another user'
    : 'its local connection could not be opened';
  Promise.resolve(vscode.window.showWarningMessage?.(
    'Lunavect Sessions is not active in this window: ' + reason +
    '. Lunavect cannot switch to sessions here until the window is reloaded.')).catch(() => {});
}

async function activate(context) {
  if (process.platform !== 'darwin' || vscode.env.remoteName) return;
  try { await start(context); } catch (error) { warn(error); }
}

async function start(context) {
  const root = path.join(os.homedir(), 'Library/Application Support/Lunavect/IDEBridge');
  const id = randomUUID();
  const sockets = socketDirectory(id);
  await privateDirectory(root); await privateDirectory(sockets);
  const socketPath = path.join(sockets, id + '.sock');
  const descriptorPath = path.join(root, id + '.json');
  const pending = new Map();
  const connections = new Set();
  const servers = new Set();
  const appPath = path.resolve(vscode.env.appRoot, '../../..');
  const descriptor = {
    version: 1, id, editor: 'vscode', companion: version, pid: process.pid, appPath,
    bundleIdentifier: await bundleIdentifier(vscode.env),
    socketPath, updatedAt: Date.now() / 1000
  };
  const handler = vscode.window.registerUriHandler({
    async handleUri(uri) {
      const key = uri.path.replace(/^\/focus\//, '');
      if (!UUID.test(key)) return;
      const request = pending.get(key);
      if (!request) return;
      pending.delete(key);
      try { request.finish(await focusTarget(vscode, request.target, request.signal)); }
      catch { request.finish({ status: 'failed' }); }
    }
  });
  const serve = socket => {
    if (connections.size >= 8) { socket.destroy(); return; }
    connections.add(socket);
    const abort = new AbortController();
    let bytes = Buffer.alloc(0), handled = false;
    const send = value => { if (!socket.destroyed) socket.write(JSON.stringify(value) + '\n'); };
    const finish = value => { send(value); socket.end(); };
    const deadline = setTimeout(() => { abort.abort(); finish({ status: 'timeout' }); socket.destroy(); }, TIMEOUT_MS);
    socket.on('error', () => socket.destroy());
    socket.on('close', () => {
      abort.abort();
      clearTimeout(deadline);
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
        pending.set(key, { socket, target: request.target, signal: abort.signal, finish });
        // Resolve at click time and pass the result unchanged. VS Code routes the
        // callback to this exact window and brings it forward before our handler.
        const uri = await vscode.env.asExternalUri(vscode.Uri.parse(vscode.env.uriScheme + '://lovach.lunavect/focus/' + key));
        if (socket.destroyed) { pending.delete(key); return; }
        send({ status: 'ready', url: uri.toString() });
      } catch { finish({ status: 'failed' }); }
    });
  };
  let timer, publishing, listening, disposal, disposed = false;
  dispose = () => {
    if (disposal) return disposal;
    disposed = true;
    clearInterval(timer); handler.dispose();
    for (const socket of connections) socket.destroy();
    for (const server of servers) server.close();
    servers.clear(); pending.clear();
    disposal = (async () => {
      // An in-flight heartbeat must finish before deleting its output.
      await Promise.all([publishing, listening].map(work => work?.catch(() => {})));
      await Promise.all([descriptorPath, descriptorPath + '.tmp', socketPath].map(file => fs.unlink(file).catch(() => {})));
    })();
    return disposal;
  };
  context.subscriptions.push({ dispose: () => { void dispose?.(); } });
  // (Re)open the endpoint. A private temporary folder can be cleaned while the
  // editor keeps running; the next heartbeat recreates it at the same path.
  const listen = async () => {
    if (listening) return listening;
    listening = (async () => {
      await privateDirectory(sockets);
      if (disposed) return;
      for (const server of servers) server.close();
      servers.clear();
      await fs.unlink(socketPath).catch(() => {});
      const server = net.createServer(serve);
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
      if (disposed) { server.close(); return; }
      servers.add(server);
      await fs.chmod(socketPath, 0o600);
    })();
    try { await listening; } finally { listening = undefined; }
  };
  const publish = async () => {
    if (disposed) return;
    if (publishing) return publishing;
    publishing = (async () => {
      descriptor.updatedAt = Date.now() / 1000;
      const temporary = descriptorPath + '.tmp';
      await fs.writeFile(temporary, JSON.stringify(descriptor), { mode: 0o600 });
      await fs.rename(temporary, descriptorPath);
    })();
    try { await publishing; } finally { publishing = undefined; }
  };
  const heartbeat = async () => {
    if (disposed) return;
    if (!(await isSocket(socketPath))) await listen();
    await publish();
  };
  try {
    await listen();
    await publish();
    if (!disposed) timer = setInterval(() => heartbeat().catch(() => {}), 30000);
  } catch (error) { await dispose(); throw error; }
}

async function deactivate() { await dispose?.(); }
module.exports = { activate, deactivate };

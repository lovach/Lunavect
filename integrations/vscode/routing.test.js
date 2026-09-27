'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateTarget, resolveTarget, focusTarget } = require('./routing');

function editor(pids) {
  const api = { env: {}, workspace: { workspaceFolders: [] }, extensions: { getExtension: () => undefined },
    window: { terminals: [], state: { focused: true } } };
  api.window.terminals = pids.map(pid => ({ processId: Promise.resolve(pid), show() { api.window.activeTerminal = this; } }));
  return api;
}

test('different sessions in one project select their individual terminal processes', async () => {
  const api = editor([20, 30]);
  const result = await focusTarget(api, { kind: 'terminal', ancestors: [42, 30, 10] });
  assert.equal(result.status, 'focused'); assert.equal(result.shellPID, 30);
  assert.equal(api.window.activeTerminal, api.window.terminals[1]);
});

test('exited and ambiguous terminals never receive focus', async () => {
  const api = editor([30, 30]);
  const target = { kind: 'terminal', ancestors: [42, 30] };
  assert.equal((await resolveTarget(api, target)).status, 'ambiguous');
  api.window.terminals[0].exitStatus = { code: 0 };
  assert.equal((await resolveTarget(api, target)).terminal, api.window.terminals[1]);
  api.window.terminals[1].exitStatus = { code: 0 };
  assert.equal((await focusTarget(api, target)).status, 'notFound');
  assert.equal(api.window.activeTerminal, undefined);
});

test('probe is read only and a closed tab is rechecked before focus', async () => {
  const api = editor([30]); const target = { kind: 'terminal', ancestors: [42, 30] };
  assert.equal((await resolveTarget(api, target)).status, 'matched');
  assert.equal(api.window.activeTerminal, undefined);
  api.window.terminals.length = 0;
  assert.equal((await focusTarget(api, target)).status, 'notFound');
});

test('remote process IDs cannot match local sessions', async () => {
  const api = editor([30]); api.env.remoteName = 'ssh-remote';
  assert.equal((await focusTarget(api, { kind: 'terminal', ancestors: [30] })).status, 'unsupported');
});

test('provider panels require the right workspace and installed provider', async () => {
  const api = editor([]);
  api.workspace.workspaceFolders = [{ uri: { scheme: 'file', fsPath: '/projects/a' } }];
  const target = { kind: 'claude', sessionID: '01234567-89ab-cdef-0123-456789abcdef', cwd: '/projects/b' };
  const realpath = async p => p;
  assert.equal((await resolveTarget(api, target, realpath)).status, 'notFound');
  target.cwd = '/projects/a';
  assert.equal((await resolveTarget(api, target, realpath)).status, 'missingProvider');
  api.extensions.getExtension = id => id === 'anthropic.claude-code' ? {} : undefined;
  assert.equal((await resolveTarget(api, target, realpath)).status, 'matched');
});

test('payload rejects commands, path controls, malformed IDs and unbounded ancestry', () => {
  assert.equal(validateTarget({ kind: 'command', command: 'echo surprise' }), false);
  assert.equal(validateTarget({ kind: 'terminal', ancestors: [1] }), false);
  assert.equal(validateTarget({ kind: 'terminal', ancestors: Array(25).fill(30) }), false);
  assert.equal(validateTarget({ kind: 'claude', sessionID: '../x', cwd: '/tmp' }), false);
  assert.equal(validateTarget({ kind: 'codex', sessionID: '01234567-89ab-cdef-0123-456789abcdef', cwd: '/tmp\ninput' }), false);
});

test('official provider routes keep the exact ID and reuse the existing Codex editor group', async () => {
  const fs = require('node:fs/promises'); const os = require('node:os'); const path = require('node:path');
  const cwd = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'lunavect-provider-')));
  try {
    for (const kind of ['claude', 'codex']) {
      const api = editor([]), calls = [], id = '01234567-89ab-cdef-0123-456789abcdef';
      api.TabInputWebview = class { constructor(viewType) { this.viewType = viewType; } };
      api.TabInputCustom = class { constructor(uri) { this.uri = uri; } };
      api.Uri = { from: ({ scheme, authority, path }) => ({ toString: () => `${scheme}://${authority}${path}` }) };
      api.ViewColumn = { Active: -1 };
      const uri = api.Uri.from({ scheme: 'openai-codex', authority: 'route', path: '/local/' + id });
      const group = { viewColumn: 2, tabs: [{ input: new api.TabInputCustom(uri) }] };
      api.window.tabGroups = { all: [group], activeTabGroup: group };
      api.workspace.workspaceFolders = [{ uri: { scheme: 'file', fsPath: cwd } }];
      api.extensions.getExtension = () => ({ activate: async () => {}, packageJSON: { contributes: { customEditors: [{ viewType: 'chatgpt.conversationEditor' }] } } });
      api.commands = { getCommands: async () => ['claude-vscode.primaryEditor.open'], executeCommand: async (...args) => {
        calls.push(args); group.activeTab = { input: kind === 'claude' ? new api.TabInputWebview('claudeVSCodePanel') : new api.TabInputCustom(args[1]) };
      } };
      assert.equal((await focusTarget(api, { kind, sessionID: id, cwd })).status, 'focused');
      if (kind === 'claude') assert.deepEqual(calls, [['claude-vscode.primaryEditor.open', id]]);
      else {
        assert.equal(calls[0][0], 'vscode.openWith'); assert.equal(calls[0][1].toString(), uri.toString());
        assert.equal(calls[0][3].viewColumn, 2);
      }
    }
  } finally { await fs.rm(cwd, { recursive: true, force: true }); }
});

test('workspace root, aliases and similarly named siblings respect path boundaries', async () => {
  const api = editor([]);
  api.extensions.getExtension = () => ({});
  const target = { kind: 'claude', sessionID: '01234567-89ab-cdef-0123-456789abcdef', cwd: '/tmp/project' };
  api.workspace.workspaceFolders = [{ uri: { scheme: 'file', fsPath: '/' } }];
  assert.equal((await resolveTarget(api, target, async p => p)).status, 'matched');
  api.workspace.workspaceFolders[0].uri.fsPath = '/alias';
  assert.equal((await resolveTarget(api, target, async p => p === '/alias' ? '/tmp' : p)).status, 'matched');
  api.workspace.workspaceFolders[0].uri.fsPath = '/tmp/pro';
  assert.equal((await resolveTarget(api, target, async p => p)).status, 'notFound');
  target.cwd = '/tmp';
  api.workspace.workspaceFolders[0].uri.fsPath = '/tmp/project';
  assert.equal((await resolveTarget(api, target, async p => p)).status, 'notFound');
});

test('provider IDs reject trailing line terminators and paths use the UTF-8 protocol budget', () => {
  const id = '01234567-89ab-cdef-0123-456789abcdef';
  for (const suffix of ['\n', '\r', '\r\n', '\u2028', '\u2029']) {
    assert.equal(validateTarget({ kind: 'claude', sessionID: id + suffix, cwd: '/tmp' }), false);
  }
  assert.equal(validateTarget({ kind: 'codex', sessionID: id, cwd: '/' + '界'.repeat(1365) }), true);
  assert.equal(validateTarget({ kind: 'codex', sessionID: id, cwd: '/' + '界'.repeat(1366) }), false);
  for (const control of ['\x7f', '\x85']) {
    assert.equal(validateTarget({ kind: 'codex', sessionID: id, cwd: '/tmp/' + control }), false);
  }
});

test('a backwards wall-clock change cannot prolong focus confirmation', async () => {
  const fs = require('node:fs/promises'), vm = require('node:vm'), path = require('node:path');
  const source = await fs.readFile(path.join(__dirname, 'routing.js'), 'utf8');
  let wall = 0, monotonic = 0, ticks = 0;
  const module = { exports: {} };
  const load = name => name === 'node:perf_hooks' ? { performance: { now: () => monotonic += 1000 } } : require(name);
  vm.runInThisContext('(function(require,module,Date,setTimeout){' + source + '\n})')(
    load, module, { now: () => wall }, callback => {
      // Virtual time avoids a loaded CI machine turning this into a timing test.
      // The old wall-clock loop escapes after ten ticks instead of hanging.
      wall = ++ticks === 10 ? 1e9 : wall - 10000;
      queueMicrotask(callback);
    });
  const api = editor([30]); api.window.state.focused = false;
  assert.equal((await module.exports.focusTarget(api, { kind: 'terminal', ancestors: [30] })).status, 'timeout');
  assert.ok(ticks < 10, 'The monotonic budget must end despite continued clock rollback');
});

test('cancellation during terminal discovery never focuses a late matching terminal', async () => {
  const api = editor([30]), abort = new AbortController();
  let release;
  api.window.terminals[0].processId = new Promise(resolve => { release = resolve; });
  const opening = focusTarget(api, { kind: 'terminal', ancestors: [30] }, abort.signal);
  abort.abort(); release(30);
  assert.equal((await opening).status, 'cancelled');
  assert.equal(api.window.activeTerminal, undefined);
});

test('cancellation during provider activation or command discovery never dispatches an open command', async () => {
  const fs = require('node:fs/promises'), os = require('node:os'), path = require('node:path');
  const cwd = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'lunavect-cancel-provider-')));
  try {
    for (const phase of ['activation', 'commands']) {
      const api = editor([]), abort = new AbortController(); let opened = 0;
      api.workspace.workspaceFolders = [{ uri: { scheme: 'file', fsPath: cwd } }];
      api.extensions.getExtension = () => ({ activate: async () => { if (phase === 'activation') abort.abort(); } });
      api.commands = { getCommands: async () => { if (phase === 'commands') abort.abort(); return ['claude-vscode.primaryEditor.open']; },
        executeCommand: async () => { opened++; } };
      const result = await focusTarget(api, { kind: 'claude', sessionID: '01234567-89ab-cdef-0123-456789abcdef', cwd }, abort.signal);
      assert.equal(result.status, 'cancelled'); assert.equal(opened, 0);
    }
  } finally { await fs.rm(cwd, { recursive: true, force: true }); }
});

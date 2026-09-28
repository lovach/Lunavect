'use strict';

const fs = require('node:fs/promises');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLAUDE_PANEL = ['mainThreadWebview-claudeVSCodePanel', 'claudeVSCodePanel'];

function validateTarget(target) {
  if (!target || !['terminal', 'claude', 'codex'].includes(target.kind)) return false;
  if (target.kind === 'terminal') {
    return Array.isArray(target.ancestors) && target.ancestors.length > 0 && target.ancestors.length <= 24 &&
      target.ancestors.every(pid => Number.isInteger(pid) && pid > 1 && pid <= 2147483647);
  }
  return typeof target.sessionID === 'string' && UUID.test(target.sessionID) &&
    typeof target.cwd === 'string' && Buffer.byteLength(target.cwd, 'utf8') <= 4096 && path.isAbsolute(target.cwd) && !/[\x00-\x1f\x7f-\x9f]/.test(target.cwd);
}

async function resolveTarget(vscode, target, realpath = fs.realpath) {
  if (!validateTarget(target) || vscode.env.remoteName) return { status: 'unsupported' };
  if (target.kind === 'terminal') {
    const entries = await Promise.all(vscode.window.terminals.map(async terminal => ({ terminal, pid: await terminal.processId })));
    const matches = entries.filter(({ terminal, pid }) => terminal.exitStatus === undefined && target.ancestors.includes(pid));
    if (matches.length !== 1) return { status: matches.length ? 'ambiguous' : 'notFound' };
    return { status: 'matched', terminal: matches[0].terminal, shellPID: matches[0].pid };
  }
  let cwd;
  try { cwd = await realpath(target.cwd); } catch { return { status: 'notFound' }; }
  const roots = await Promise.all((vscode.workspace.workspaceFolders || []).map(async folder => {
    if (folder.uri.scheme !== 'file') return null;
    try { return await realpath(folder.uri.fsPath); } catch { return null; }
  }));
  if (!roots.some(root => {
    if (!root) return false;
    const relative = path.relative(root, cwd);
    return relative === '' || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith('..' + path.sep));
  })) return { status: 'notFound' };
  const extensionID = target.kind === 'claude' ? 'anthropic.claude-code' : 'openai.chatgpt';
  if (!vscode.extensions.getExtension(extensionID)) return { status: 'missingProvider' };
  return { status: 'matched' };
}

async function focusTarget(vscode, target, signal) {
  const cancelled = () => signal?.aborted === true;
  if (cancelled()) return { status: 'cancelled' };
  // Re-resolve when the callback arrives: tabs may close after the initial probe.
  const resolved = await resolveTarget(vscode, target);
  if (cancelled()) return { status: 'cancelled' };
  if (resolved.status !== 'matched') return resolved;
  if (target.kind === 'terminal') {
    resolved.terminal.show(false);
    const deadline = performance.now() + 2500;
    while (performance.now() < deadline) {
      if (cancelled()) return { status: 'cancelled' };
      if (vscode.window.activeTerminal === resolved.terminal && vscode.window.state.focused) {
        return { status: 'focused', shellPID: resolved.shellPID };
      }
      if (resolved.terminal.exitStatus !== undefined) return { status: 'notFound' };
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    return { status: 'timeout' };
  }
  const extensionID = target.kind === 'claude' ? 'anthropic.claude-code' : 'openai.chatgpt';
  await vscode.extensions.getExtension(extensionID).activate();
  if (cancelled()) return { status: 'cancelled' };
  if (target.kind === 'claude') {
    const command = 'claude-vscode.primaryEditor.open';
    const commands = await vscode.commands.getCommands();
    if (cancelled()) return { status: 'cancelled' };
    if (!commands.includes(command)) return { status: 'unsupportedProvider' };
    await vscode.commands.executeCommand(command, target.sessionID);
  } else {
    // The official Codex extension registers this custom editor and URI shape.
    // Reuse an already open editor group rather than creating another panel.
    const uri = vscode.Uri.from({ scheme: 'openai-codex', authority: 'route', path: '/local/' + target.sessionID });
    const group = vscode.window.tabGroups.all.find(group => group.tabs.some(tab =>
      tab.input instanceof vscode.TabInputCustom && tab.input.uri.toString() === uri.toString()));
    const editor = vscode.extensions.getExtension(extensionID).packageJSON.contributes?.customEditors?.some(
      editor => editor.viewType === 'chatgpt.conversationEditor');
    if (!editor) return { status: 'unsupportedProvider' };
    await vscode.commands.executeCommand('vscode.openWith', uri, 'chatgpt.conversationEditor',
      { viewColumn: group?.viewColumn ?? vscode.ViewColumn.Active, preserveFocus: false, preview: false });
  }
  const deadline = performance.now() + 2500;
  while (performance.now() < deadline) {
    if (cancelled()) return { status: 'cancelled' };
    const input = vscode.window.tabGroups.activeTabGroup.activeTab?.input;
    // Extension webview panels report the workbench's 'mainThreadWebview-' prefix in
    // TabInputWebview.viewType; the bare name is accepted as well.
    const selected = target.kind === 'claude'
      ? input instanceof vscode.TabInputWebview && CLAUDE_PANEL.includes(input.viewType)
      : input instanceof vscode.TabInputCustom && input.uri.toString() ===
        vscode.Uri.from({ scheme: 'openai-codex', authority: 'route', path: '/local/' + target.sessionID }).toString();
    if (selected && vscode.window.state.focused) return { status: 'focused' };
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  return { status: 'timeout' };
}

module.exports = { UUID, validateTarget, resolveTarget, focusTarget };

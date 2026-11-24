#!/usr/bin/env node
// Drives the real hook over stdin, as Claude Code does, against a throwaway cache root.
// Run: node plugins/op-cli/test/gate.test.mjs
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOOK = fileURLToPath(new URL('../hooks/gate.mjs', import.meta.url));
const root = mkdtempSync(join(tmpdir(), 'opgate-'));
const env = { ...process.env, CLAUDE_OPCACHE_DIR: root };
const OP = 'o' + 'p';   // keep the live gate from matching this file's own test commands
let failed = 0;

const run = (payload) => spawnSync(process.execPath, [HOOK], { input: JSON.stringify(payload), encoding: 'utf8', env });
const tool = (sid, tool_name, tool_input) => run({ hook_event_name: 'PreToolUse', session_id: sid, tool_name, tool_input });
const check = (name, ok) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`); if (!ok) failed++; };

try {
  const ps = (sid, command) => tool(sid, 'PowerShell', { command }).status;

  check('ordinary command allowed', ps('s1', 'Get-ChildItem; $operator = 1') === 0);
  check('op:// text alone allowed', ps('s1', "Write-Host 'op://V/i/f'") === 0);
  check('operator word allowed', ps('s1', 'Get-Service | Where-Object Name -eq operator') === 0);
  check('-Op parameter allowed', ps('s1', 'Foo -Op read') === 0);
  for (const cmd of [`$pw = ${OP} read 'op://V/i/f'`, `${OP} item list --vault X`, `& ${OP}.exe whoami`, `x; ${OP} run -- y`,
    `${OP.toUpperCase()} READ x`, `${OP} --account x read 'op://V/i/f'`, `${OP} --format=json item list`,
    `& 'C:\\Program Files\\1Password CLI\\${OP}.exe' read x`, `/usr/local/bin/${OP} whoami`,
    "$pw = Get-OpSecret 'op://V/i/f'", '. "$env:LOCALAPPDATA\\claude-opcache\\OpSecret.ps1"']) {
    const r = tool('s1', 'PowerShell', { command: cmd });
    check(`denied unmarked: ${cmd}`, r.status === 2 && r.stderr.includes('op-cli'));
  }
  check('Bash tool gated too', tool('s1', 'Bash', { command: `${OP} vault list` }).status === 2);

  check('other skill does not mark', tool('s1', 'Skill', { skill: 'brandon-mixed:powershell-style' }).status === 0
    && ps('s1', `${OP} whoami`) === 2);
  tool('s1', 'Skill', { skill: 'op-cli:op-cli' });
  check('allowed after Skill load', ps('s1', `${OP} whoami`) === 0);
  check('marker is per session', ps('s2', `${OP} whoami`) === 2);

  run({ hook_event_name: 'UserPromptSubmit', session_id: 's3', prompt: '/op-cli can you look up X' });
  check('slash command marks', ps('s3', `${OP} whoami`) === 0);
  run({ hook_event_name: 'UserPromptSubmit', session_id: 's4', prompt: 'look up X, use /op-cli:op-cli' });
  check('slash command mid-prompt marks', ps('s4', `${OP} whoami`) === 0);
  run({ hook_event_name: 'UserPromptSubmit', session_id: 's5', prompt: 'see /op-cli-notes and a/op-cli' });
  check('lookalike slash does not mark', ps('s5', `${OP} whoami`) === 2);

  // Subagents share session_id; each carries its own agent_id and its own marker.
  const sub = (aid, tool_name, tool_input) => run({ hook_event_name: 'PreToolUse', session_id: 's3', agent_id: aid, tool_name, tool_input });
  check('subagent does not inherit parent marker', sub('a1', 'PowerShell', { command: `${OP} whoami` }).status === 2);
  sub('a1', 'Skill', { skill: 'op-cli:op-cli' });
  check('subagent allowed after its own Skill load', sub('a1', 'PowerShell', { command: `${OP} whoami` }).status === 0);
  check('sibling subagent still gated', sub('a2', 'PowerShell', { command: `${OP} whoami` }).status === 2);

  // SessionStart: copies the helper to a stable path; resume|clear|compact drop markers, keep secrets.
  run({ hook_event_name: 'SessionStart', session_id: 's3', source: 'startup' });
  check('SessionStart copies OpSecret.ps1 to the cache root', existsSync(join(root, 'OpSecret.ps1')));
  check('startup keeps markers', ps('s3', `${OP} whoami`) === 0);
  writeFileSync(join(root, 's3', 'secret.bin'), 'x');
  run({ hook_event_name: 'SessionStart', session_id: 's3', source: 'resume' });
  check('resume drops session and subagent markers', ps('s3', `${OP} whoami`) === 2
    && sub('a1', 'PowerShell', { command: `${OP} whoami` }).status === 2);
  check('resume keeps the rest of the folder', existsSync(join(root, 's3', 'secret.bin')));
  tool('s3', 'Skill', { skill: 'op-cli:op-cli' });
  run({ hook_event_name: 'SessionStart', session_id: 's3', source: 'compact' });
  check('compact drops the marker', ps('s3', `${OP} whoami`) === 2);
  check('SessionStart for an unseen session is fine', run({ hook_event_name: 'SessionStart', session_id: 's9', source: 'clear' }).status === 0);

  run({ hook_event_name: 'SessionEnd', session_id: 's1' });
  check('SessionEnd deletes the session folder', !existsSync(join(root, 's1')) && existsSync(join(root, 's3')));

  check('garbage input fails open', spawnSync(process.execPath, [HOOK], { input: 'not json', encoding: 'utf8', env }).status === 0);
} finally {
  rmSync(root, { recursive: true, force: true });
}

if (failed) { console.error(`${failed} failed`); process.exit(1); }
console.log('All gate checks passed.');

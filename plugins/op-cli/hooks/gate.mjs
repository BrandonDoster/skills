#!/usr/bin/env node
// op-cli hooks. One file, dispatched on hook_event_name:
//
//   PreToolUse  Skill             the op-cli skill loaded -> mark this session
//   UserPromptSubmit              the user typed /op-cli  -> mark this session
//   PreToolUse  Bash|PowerShell   an `op` command in an unmarked session -> deny (exit 2)
//   SessionStart                  copy OpSecret.ps1 to the cache root (a path that survives version
//                                 bumps and marketplace moves); on resume|clear|compact also drop
//                                 the markers, since a resume or compact keeps the session id
//   SessionEnd                    delete this session's cache folder (encrypted secrets + marker)
//
// Subagents share the parent's session_id but carry agent_id, so each gets its own marker.
//
// The gate exists because the model knows `op` well enough to never load the skill on its own,
// and the skill is where the never-print-a-secret rules live. A deny costs one retry.
//
// FAILS OPEN on purpose: any error exits 0. This is a nudge toward the skill, not a security
// boundary, and failing closed would block every shell call over a bookkeeping problem.
//
// The cache root must match Get-OpCacheRoot in skills/op-cli/scripts/OpSecret.ps1.
import { copyFileSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const cacheRoot = () => process.env.CLAUDE_OPCACHE_DIR
  || join(process.env.LOCALAPPDATA || join(homedir(), '.cache'), 'claude-opcache');

// `op` as a command word (any case, bare or by path, global flags allowed) followed by a
// subcommand, or the Get-OpSecret helper. Not `operator`, not `op://` on its own.
export const OP_COMMAND = /(^|[\s;|&({=!'"\\/])op(\.exe)?['"]?(\s+-\S+(\s+[^-\s]\S*)?)*\s+(read|item|inject|run|vault|document|whoami|account|signin|user|group|service-account)\b|\bGet-OpSecret\b|\bOpSecret\.ps1\b/i;
const SKILL = /(^|:)op-cli$/;
const SLASH = /(^|\s)\/(op-cli:)?op-cli(?![\w-])/;
const HELPER = fileURLToPath(new URL('../skills/op-cli/scripts/OpSecret.ps1', import.meta.url));

const DENY = 'Load the op-cli skill first (Skill tool, skill "op-cli:op-cli"), then retry this command. '
  + 'It carries the mandatory 1Password rules: never print a secret, and use Get-OpSecret so each '
  + 'credential prompts once per session.';

try {
  const input = JSON.parse(readFileSync(0, 'utf8'));
  const sid = String(input.session_id ?? '').replace(/[^\w-]/g, '');
  if (!sid) process.exit(0);
  const dir = join(cacheRoot(), sid);
  const aid = String(input.agent_id ?? '').replace(/[^\w-]/g, '');
  const marker = join(dir, aid ? `.skill-loaded-${aid}` : '.skill-loaded');
  const mark = () => { mkdirSync(dir, { recursive: true }); writeFileSync(marker, ''); };

  switch (input.hook_event_name) {
    case 'SessionStart':
      mkdirSync(cacheRoot(), { recursive: true });
      copyFileSync(HELPER, join(cacheRoot(), 'OpSecret.ps1'));
      if (/^(resume|clear|compact)$/.test(input.source) && existsSync(dir)) {
        for (const f of readdirSync(dir)) if (f.startsWith('.skill-loaded')) rmSync(join(dir, f));
      }
      break;
    case 'SessionEnd':
      rmSync(dir, { recursive: true, force: true });
      break;
    case 'UserPromptSubmit':
      if (SLASH.test(String(input.prompt ?? ''))) mark();
      break;
    case 'PreToolUse':
      if (input.tool_name === 'Skill') {
        if (SKILL.test(String(input.tool_input?.skill ?? ''))) mark();
      } else if (OP_COMMAND.test(String(input.tool_input?.command ?? '')) && !existsSync(marker)) {
        process.stderr.write(DENY + '\n');
        process.exit(2);
      }
      break;
  }
} catch { /* fail open, see header */ }
process.exit(0);

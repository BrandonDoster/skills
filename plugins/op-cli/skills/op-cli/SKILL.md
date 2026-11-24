---
name: op-cli
description: REQUIRED before running any `op` / `op.exe` command or resolving any `op://` reference. Also use whenever a task needs a password, token, API key, or admin credential (to connect to vCenter, ServiceNow, Exchange, APIs, etc.), even if the user never says 1Password. Carries mandatory rules - secrets never printed to stdout, and Get-OpSecret so each credential prompts once per session. Also covers creating items, checking an item exists in a vault, and the per-user vault notes file.
---

# 1Password CLI (`op`)

Windows + PowerShell. `op.exe` is on PATH and integrated with the 1Password desktop app. Do **not** run `op signin` — the desktop integration handles auth.

**How prompts work.** 1Password authorizes per process, and every PowerShell/Bash tool call is a new process. So each tool call that runs `op` raises one desktop prompt; any number of `op` commands inside that one call share it. The call blocks until the user approves; if it times out, tell the user to approve the pending 1Password prompt, then retry.

A hook in this plugin denies raw `op` commands until this skill is loaded in the session. That is why you are reading this.

## SESSION CACHE — every credential prompts once per session

**Resolve secrets through `Get-OpSecret`, not `op read`.** It caches each value for the rest of this Claude session, so no later tool call prompts for it again. A new or resumed session starts empty and prompts again; that is intended.

```powershell
. "<base directory of this skill>\scripts\OpSecret.ps1"      # once per tool call; shell state does not persist

$pw = Get-OpSecret 'op://Private/Example Login/password'   # first time this session: one prompt

## Several at once: ONE prompt for all of them. Returns a hashtable keyed by reference.
$c = Get-OpSecret 'op://Infra/vcenter-admin/username', 'op://Infra/vcenter-admin/password', 'op://Infra/esx-root/password'
$user = $c['op://Infra/vcenter-admin/username']

$pw = Get-OpSecret 'op://Private/Example Login/password' -Force   # re-read after a rotation
Clear-OpSecretCache                                                     # wipe this session's cache now
```

The base directory is printed at the top of this skill when it loads ("Base directory for this skill: ..."). Use that full path in a tool call. **In a script file**, dot-source the stable copy instead: `. "$env:LOCALAPPDATA\claude-opcache\OpSecret.ps1"`. A hook refreshes it at every session start; the base directory changes with each plugin version.

**Batch up front.** If you know you need several credentials, name them all in one `Get-OpSecret` call: one prompt instead of one per tool call. If one turns out wrong and you need a different item, request just the new one — already-cached values never prompt again.

How it is stored: each value is DPAPI-encrypted to the current Windows user under `%LOCALAPPDATA%\claude-opcache\<session id>\`. The folder belongs to the Claude process that created it; a resumed session (a new process) cannot use it, the SessionEnd hook deletes it, and folders of dead sessions are wiped on the next call. Never read, copy, or print those files.

If a secret looks stale (auth suddenly failing after a rotation), re-fetch with `-Force` before debugging anything else.

## GOLDEN RULE — a resolved secret must NEVER reach stdout

The output of every tool call is captured verbatim into the Claude session transcript. **Anything a command prints is now permanently in context** — logged, cached, unredactable. A resolved secret (password, token, key, connection string) must never be printed, returned, or be the value of the last expression in a pipeline.

**Never** do any of these — each one dumps the secret to the transcript:
- `op read 'op://...'` or `Get-OpSecret ...` on its own line (no assignment → prints)
- `op item get ... --format=json | ConvertFrom-Json` with no assignment
- `op item get ... | Select-Object value` / `Format-List value`
- `op item create ...` with no assignment — its output includes the password, generated or not
- `Write-Host $pw`, `echo $pw`, `$pw` alone, `"pw is $pw"`, `$c` (the hashtable) alone

**Instead**, a secret only ever lands in a variable, is used, and is scrubbed:
```powershell
$pw = Get-OpSecret 'op://<vault>/<item>/password'   # assignment → nothing printed
# ... build a header, PSCredential, connection, etc. ...
$pw = $null
```

To confirm a secret resolved without revealing it, print its **length or a boolean**:
```powershell
$pw = Get-OpSecret 'op://<vault>/<item>/password'; "len=$($pw.Length)"
```

When a command must return JSON containing secret fields, select only non-secret fields (`Select-Object id,label,type` — never `value`), or capture the object into a variable and index the field you need without echoing it. Username/host/id are not secrets; passwords/tokens/keys/credentials are.

**Do not write resolved secrets to files.** Pass them in memory: variables, `op run` (env vars for a child process), or pipe `op inject` output straight into the consumer. If a tool truly can only read a secret from a file, stop and ask the user where it may go.

This rule overrides convenience everywhere below.

## Output format rule

Default `op` output is human-readable and brittle to parse. **Always pass `--format=json`** when you intend to read the result programmatically, assign it, then pick fields:

```powershell
$item = op item get 'GitHub PAT' --vault Engineering --format=json | ConvertFrom-Json
$item | Select-Object id, title, category, vault
```

For human display of non-secret listings (a vault list, item titles), omit `--format=json`.

## Vault scoping rule

**Every `op item` call must include `--vault <name-or-id>`** unless explicitly told otherwise:
1. Item names are not unique across vaults. Without `--vault`, `op item get` may match the wrong item or fail with "more than one item matches".
2. It is the only way to validate that an item lives in the expected vault.

Vault names with spaces must be quoted: `--vault "Team Shared"`.

## Sign-in / account check

```powershell
op whoami                       # signed-in account, user URL + email
op account list --format=json   # configured accounts
op vault list --format=json     # vaults visible to the current account
```

If `op whoami` errors with `you are not currently signed in`, ask the user to unlock the desktop app. Do not run `op signin` — it conflicts with desktop integration on Windows.

## Creating items

General shape — **always assign the result**, it echoes the item including its password:

```powershell
$created = op item create `
  --category <Category> `
  --title    '<Title>' `
  --vault    '<Vault>' `
  [--url <url>] `
  [--tags <tag1,tag2>] `
  [--generate-password[=recipe]] `
  --format=json `
  field1=value1 field2=value2 ... | ConvertFrom-Json
"created $($created.id)"
```

Backtick (`` ` ``) is the PowerShell line continuation. Assignment statements (`field=value`) are positional args — they go **after** all flags.

### Common categories

| Category         | Use for                                  |
|------------------|------------------------------------------|
| `Login`          | Username/password + URL (web logins)     |
| `Password`       | Standalone password, no username         |
| `API Credential` | API tokens, PATs, service account keys   |
| `Database`       | DB creds (host/port/user/pass/database)  |
| `Secure Note`    | Free-form text, recovery codes           |
| `Server`         | SSH/RDP host credentials                 |

`--category` is case-insensitive and ignores spaces (`apicredential` == `API Credential`).

### Built-in field names per category

- **Login** — `username`, `password`, plus URL via `--url` or `website=`
- **API Credential** — `username`, `credential`, `type`, `filename`, `valid_from`, `expires`, `hostname`
- **Database** — `type`, `hostname`, `port`, `database`, `username`, `password`, `sid`, `alias`, `connection options`
- **Server** — `username`, `password`, `url`
- **Password** — `password`

### Examples

**Login with generated password:**
```powershell
$created = op item create --category Login --title 'Jenkins admin' --vault 'Team Shared' `
  --url https://jenkins.internal --generate-password='letters,digits,symbols,32' `
  --format=json username=admin | ConvertFrom-Json
"created $($created.id)"
```

**API Credential (token)** — the token value comes from a variable, never typed into the command:
```powershell
$created = op item create --category 'API Credential' --title 'GitHub PAT - automation' `
  --vault Engineering --format=json `
  username=svc-automation "credential=$token" `
  hostname=github.com expires=2027-01-01 | ConvertFrom-Json
$token = $null
```

**Custom fields with sections** — syntax is `'Section.field=value'` (quote the whole thing so PowerShell doesn't choke on the dot or space):
```powershell
$created = op item create --category Login --title 'Vendor portal' --vault Procurement --format=json `
  username=jdoe --generate-password `
  'Account Info.Account Number=ACCT-12345' `
  'Account Info.Renewal Date[date]=2027-04-01' | ConvertFrom-Json
```

Field type override syntax: `'label[type]=value'` where type ∈ `text|password|email|url|date|monthYear|phone|otp|file|concealed`.

### Template method (for complex items) — in memory, no file

```powershell
$t = op item template get Login | ConvertFrom-Json
($t.fields | Where-Object id -eq 'username').value = 'admin'
$created = $t | ConvertTo-Json -Depth 10 | op item create --vault Engineering --format=json | ConvertFrom-Json
"created $($created.id)"
```

## Validating an item exists in a specific vault

**1. Exact-name lookup, fail-fast:**
```powershell
$null = op item get '<title>' --vault '<vault>' --format=json 2>$null
if ($LASTEXITCODE -eq 0) { 'found' } else { 'missing' }
```
Exit 0 = exists. Non-zero = missing or ambiguous.

**2. Existence-only, no secret payload:**
```powershell
op item get '<title>' --vault '<vault>' --fields label=id --format=json 2>$null | ConvertFrom-Json
```

**3. List-and-filter (fuzzy/prefix matches or bulk validation)** — list output has no secret values:
```powershell
op item list --vault '<vault>' --format=json |
  ConvertFrom-Json |
  Where-Object { $_.title -like '*portal*' }
```

**Never grep on plaintext `op item list` output** — column widths shift with content.

## Reading fields

- **Single value, or several:** `Get-OpSecret` (above). Always the default.
- **Several fields of one item as objects:** capture into a variable, never let it print:
  ```powershell
  $cred = op item get '<title>' --vault '<vault>' --fields label=username,label=password --format=json | ConvertFrom-Json
  # $cred.value holds the secret — use it, never echo it. Non-secret peek: $cred | Select id,label
  ```
  This bypasses the cache, so it prompts in every tool call it runs in. Prefer `Get-OpSecret` with one reference per field.

Spaces in vault/item/field names work as-is when the reference is single-quoted: `'op://Team Shared/Jenkins admin/password'`.

## Secret references & injection

- `Get-OpSecret 'op://vault/item/field'` — cached, the default. **Assign it.**
- `op read 'op://vault/item/field'` — uncached, prompts every tool call. Only when the helper cannot be used, and **assigned**.
- `op run --env-file=.env -- <command>` — run a process with secrets as env vars. A `.env` of references (`DB_PASS=op://vault/item/password`) holds no secrets and can live anywhere.
- `op inject -i template.tpl | <consumer>` — fill `{{ op://... }}` placeholders and pipe straight on. Do not write the output to a file (see Golden Rule).

## PowerShell gotchas

- **Quote any `field=value` arg containing spaces, dots, or special chars.**
- **Single-quote literals.** Double quotes interpolate `$` — use them only when deliberately inserting a variable.
- **`$LASTEXITCODE`, not `$?`,** for `op` exit status.
- **`--format=json` outputs UTF-8 without BOM.** `ConvertFrom-Json` handles it; don't pipe through `Out-String` first.

## Common errors → fix

| Error                                                  | Fix                                                                                  |
|--------------------------------------------------------|--------------------------------------------------------------------------------------|
| `[ERROR] ... isn't an item in the "X" vault`           | Wrong vault, wrong title, or item lives elsewhere. Use `op item list --vault X`.     |
| `more than one item matches "X"`                       | Add `--vault`, or pass the item's UUID instead of title.                             |
| `you are not currently signed in`                      | Ask the user to unlock the 1Password desktop app. Do not run `op signin`.            |
| `invalid field assignment ...`                         | Field has spaces/dots — wrap the whole `field=value` arg in single quotes.           |
| `[ERROR] config directory ... not allowed`             | Running under wrong user context (scheduled task, etc.). Set `$env:OP_CONFIG_DIR`.   |
| `Get-OpSecret`: `CLAUDE_CODE_SESSION_ID ... not set`   | Not inside a Claude Code tool call. Use `op read` assigned to a variable.            |
| `Get-OpSecret`: `op read failed for: ...`              | Prompt not approved, app locked, or bad reference. Others in that call were cached.  |

---

## Vault lookup table

Per user, not in this plugin: **`~/.claude/op-cli-vaults.md`** (`$HOME\.claude\op-cli-vaults.md`). Read it before working in a vault whose purpose is not obvious from its name. When the user mentions such a vault, or you query one repeatedly during a session, add an entry (create the file with the table header below if it does not exist). Before adding, run `op vault list --format=json` to confirm the exact name + ID.

```markdown
| Vault name (exact) | Vault ID | Used for | Notes |
|--------------------|----------|----------|-------|
```

Entry rules:
- **Vault name** is the canonical name from `op vault list` — copy it exactly.
- **Vault ID** is the 26-char ID (lets you target a renamed vault).
- **Used for** is one short phrase: what category of secret lives there.
- **Notes** captures non-obvious gotchas: shared-with-whom, naming conventions, rotation cadence.

If a vault's name is self-describing (`Personal`, `Engineering`, `DB Creds`) **do not** add an entry.

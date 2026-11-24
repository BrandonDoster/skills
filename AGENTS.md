# Agent rules for this repo (PUBLIC)

Everything committed here is public the moment it is pushed. Treat every change as published.

## Never
- `--no-verify`, `-c commit.gpgsign=false`, `--author`, or editing hooks/CI/rulesets to get a commit through.
- Allowlist or `gitleaks:allow` a finding. Remove the content instead.
- Commit personal or employer details: real email addresses (only the owner's GitHub noreply address),
  company names/domains, hostnames, IPs, local paths (`C:\Users\...`, `/home/...`), machine names,
  vault or item names, tokens, internal URLs.
- Copy a file in from a private repo without reading it line by line first. `plugin.json` author is name only.

## A hook blocked the commit
Fix the content or ask the user. Do not work around it.

## Clone setup (once per machine)
The pre-commit hook refuses to run until this is in place:
- Repo-local git config: `user.name`, `user.email` (the noreply address the hooks expect),
  `gpg.format ssh`, `user.signingkey` (a key registered on GitHub as a signing key),
  `commit.gpgsign true`, `tag.gpgsign true`, `core.hooksPath .githooks`.
- `gitleaks` on PATH.
- `~/.config/gitleaks/private.toml`: the owner's private gitleaks rules, kept outside any repo. Ask the user if missing.

`main` requires signed commits and rejects force-pushes and deletion.

## Layout
- `.claude-plugin/marketplace.json`: marketplace `brandon-skills`; list each plugin here.
- `plugins/<name>/`: one plugin each, with `.claude-plugin/plugin.json`.
- Run `claude plugin validate .` before committing.

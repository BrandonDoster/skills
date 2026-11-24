# skills

Public Claude Code skills by Brandon Doster.

```
/plugin marketplace add BrandonDoster/skills
/plugin install op-cli@brandon-skills
```

| Plugin | What |
|---|---|
| [op-cli](plugins/op-cli) | 1Password CLI skill + hooks: one prompt per credential per session, secrets kept out of the transcript. Windows. |

## Contributing / cloning

One-time setup per clone: see [AGENTS.md](AGENTS.md#clone-setup-once-per-machine).

`pre-commit` runs gitleaks on staged changes and checks the commit identity and signing.
`pre-push` rejects any commit that is unsigned or not from the GitHub noreply address.
CI runs gitleaks on every push and PR.

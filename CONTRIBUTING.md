# Contributing

## Dev setup

1. Fork and clone. Do not put real keys or numbers in the tree.
2. Read [docs/SETUP.md](docs/SETUP.md) and [docs/SKILLS.md](docs/SKILLS.md). The runtime skill, first-party phone skills, voice prompt, and inline TeXML template are the product; this repo is a Cursor plugin marketplace ([`.cursor-plugin/marketplace.json`](.cursor-plugin/marketplace.json) at the repo root, plugin at [`plugins/phonezero/`](plugins/phonezero/)). Contributing a skill is **optional** — Cursor users can keep a folder in `~/.phonezero/skills` or `~/.cursor/skills`. Grok users interview into a `phonezero-task` and are not asked to PR.
3. Load the plugin locally per [Test plugins locally](https://cursor.com/docs/plugins#test-plugins-locally): copy `plugins/phonezero/` to `~/.cursor/plugins/local/phonezero` (`rsync -a plugins/phonezero/ ~/.cursor/plugins/local/phonezero/`), then Reload Window. Fill the Configure card (`TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `XAI_API_KEY`) on a dedicated Telnyx account. Start a **new** conversation after install or a plugin update. Runtime: `POST https://api.x.ai/v1/stt` and Files; setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Never `source ~/.phonezero/env`. Use fixture numbers in docs and fixtures only (`+15555550100`-style). Add any new example number to [`scripts/privacy-phone-allowlist.txt`](scripts/privacy-phone-allowlist.txt) first.
4. Set a non-personal Git identity before you commit (`Function1st` + a `users.noreply.github.com` address). CI rejects personal mailbox authors.
   ```
   git config user.name Function1st
   git config user.email function1st@users.noreply.github.com
   ```
5. Run `scripts/setup-check.sh` after any TeXML, SIP, or Builder change.
6. CI must stay green: secret scan, `shellcheck` on `scripts/*.sh`, `node plugins/phonezero/scripts/xai-mcp.mjs --self-test`, `node plugins/phonezero/scripts/launch-xai-mcp.mjs --resolve-only`, `end_call.md` verbatim in `voice-agent.md`, `xmllint --noout` on `texml/*.xml` and `plugins/phonezero/texml/*.xml`, and `python3 scripts/privacy-check.py` (E.164 / US numbers, file-content emails, and commit-author emails).

## Regression suite

The persona checklist is the regression suite. After any change to `plugins/phonezero/prompts/voice-agent.md` or call-flow rules in `plugins/phonezero/skills/phonezero-runtime/SKILL.md` / a first-party skill, re-run **all scenarios** in [docs/PERSONAS.md](docs/PERSONAS.md) (restaurant) and the hours scripts. The voice agent must not speak a recap; classify from the transcript. Prompt/TeXML lint and `setup-check.sh` are the cheap gates; personas are the quality gate. A first-party skill PR needs privacy-check + personas. Grok users are not asked to contribute.

## Releases

Bump `version` in `plugins/phonezero/.cursor-plugin/plugin.json`, `.cursor-plugin/marketplace.json` (`metadata.version`), and `plugins/phonezero-grok/.grok-plugin/plugin.json` on every change that should reach installs.

**Never rewrite published history.** Marketplace and Team Marketplace installs pin the commit SHA and re-fetch that exact SHA (`git fetch --depth 1 origin <sha>`). A force-push that removes a pinned commit breaks those installs with `fatal: not our ref`. Normal commits only on `main`.

## Pull requests

- One concern per PR. Say which persona you re-ran, or why a prompt-only change skipped the live pass.
- Parameterize everything. No account SIDs, application IDs, or agent IDs that belong to a real tenant.
- Do not add a server, webhook, or tunnel to the default path.
- Keep disclosure default **on**, Telnyx voice-profile dest default `US` on create, and attempt/hours caps intact unless the PR is explicitly changing a safety default — and then say so in the title.
- Do not add jurisdiction-specific legal or compliance guidance. Name defaults; point at [DISCLAIMER.md](DISCLAIMER.md).

## Fixtures

**No real phone numbers and no real transcripts, ever.** Fixtures are listed in [`scripts/privacy-phone-allowlist.txt`](scripts/privacy-phone-allowlist.txt) (today the reserved `+15555550100`–`+15555550199` / `555-01xx` block). Transcripts are synthetic. CI rejects other E.164 numbers, mailbox addresses in the tree (GitHub noreply and `example.com` / `example.org` / `example.net` only), and personal commit-author emails.

## Secret-scanning gate

Every push and pull request runs [gitleaks](https://github.com/gitleaks/gitleaks-action). A leak fails the build. If you trip it with a false positive, fix the string; do not disable the scan. Rotate any credential that has been in git history before you continue.

# Contributing

## Dev setup

1. Fork and clone. Do not put real keys or numbers in the tree.
2. Read [docs/PLAN.md](docs/PLAN.md) and [docs/SETUP.md](docs/SETUP.md). The skill, voice prompt, and inline TeXML template are the product; this repo's packaging is the marketplace wrapper.
3. Install the plugin from your branch's repo URL (pointing Grok Bot at the branch only routes it to the skill — the plugin install is still required for the Telnyx MCP and variables) and fill the plugin variables from `.cursor-plugin/plugin.json` on a dedicated Telnyx account. Enter `XAI_API_KEY` via Grok Bot's secure secret request flow (not a plugin variable; runtime: `POST https://api.x.ai/v1/stt`; setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`). Use fixture numbers in docs and fixtures only (`+15555550100`-style).
4. Run `scripts/setup-check.sh` after any TeXML, SIP, or Builder change.
5. CI must stay green: secret scan, `shellcheck` on `scripts/*.sh`, `xmllint --noout` on `texml/*.xml`, and the phone-number guard.

## Regression suite

The persona checklist is the regression suite. After any change to `prompts/voice-agent.md` or call-flow rules in `skills/phonezero/SKILL.md`, re-run **all scenarios** in [docs/PERSONAS.md](docs/PERSONAS.md). Assert the spoken recap is correct each time. Prompt/TeXML lint and `setup-check.sh` are the cheap gates; personas are the quality gate.

## Pull requests

- One concern per PR. Say which persona you re-ran, or why a prompt-only change skipped the live pass.
- Parameterize everything. No account SIDs, application IDs, or agent IDs that belong to a real tenant.
- Do not add a server, webhook, or tunnel to the default path. That belongs in the control-plane appendix, not v1.
- Keep disclosure default **on**, calling US-only, and attempt/hours caps intact unless the PR is explicitly changing a safety default — and then say so in the title.

## Fixtures

**No real phone numbers and no real transcripts, ever.** Fixtures are `+15555550100`–`+15555550199` (and the reserved `555-01xx` block). Transcripts are synthetic. CI fails the build if a real-looking number appears.

## Secret-scanning gate

Every push and pull request runs [gitleaks](https://github.com/gitleaks/gitleaks-action). A leak fails the build. If you trip it with a false positive, fix the string; do not disable the scan. Rotate any credential that has been in git history before you continue.

# Security

## Reporting

Report vulnerabilities privately with [GitHub Private Vulnerability Reporting](https://github.com/function1st/PhoneZero/security/advisories/new). That is a security channel only — not product support. Do not open a public issue.

Enable the feature on this repository if the form is not yet available: **Settings → Code security → Private vulnerability reporting**.

Include the affected version, a repro that uses only fixture numbers, and impact. Do not send secrets or live call recordings.

## Key handling

Two keys. Different homes. Telnyx cannot transcribe Dial-verb recordings, so STT is on the default path.

| Secret | Where it lives | Rule |
|---|---|---|
| Telnyx API key | Cursor **plugin variable** `TELNYX_API_KEY` | Entered in Plugins → Configure. Injected only as env `TELNYX_API_KEY` into the Telnyx stdio MCP. Never in the agent shell, repo, or chat. |
| xAI API key | Cursor **plugin variable** `XAI_API_KEY` | Entered on the same Configure card, from a team with ZDR off. Injected only into the PhoneZero xAI MCP (`plugins/phonezero/scripts/xai-mcp.mjs`) for Files, collections, STT, and phone-numbers. Never in the agent shell. Never pasted in chat. Never written to `.env` or `source ~/.phonezero/env`. |

Voice Agent Builder holds its own console credentials on xAI's side; that is not a PhoneZero plugin variable.

There is no PhoneZero server and no PhoneZero-held key. Revoke at the vendor: rotate the Telnyx key in Mission Control and update the plugin variable; rotate the xAI key in the xAI console and re-enter it on the Configure card, then start a new conversation.

## Blast radius

- Use a **dedicated Telnyx account** for PhoneZero. Plugins are account-wide; a shared Telnyx account shares every number and recording on that account with every Bot that can call the MCP.
- Set a **Telnyx daily spend cap** on the outbound voice profile and an **xAI spend limit** (prepaid / monthly top-up max) during setup. The skill cannot enforce spend.
- Keys are revocable at Telnyx and xAI. Treat a leaked plugin-variable value as a live credential and rotate it.

## Account-wide Bot computer

Grok Bot's computer is account-wide: all Bots on the account share files, browser sessions, and command-line credentials. Disk is the worst place for a PhoneZero secret. Both keys live in the plugin variable store and reach vendors only inside MCP child processes. Do not work around this by writing `.env` files, stuffing keys into `agent-tools/`, pasting keys in chat, `source ~/.phonezero/env`, or asking the Bot to `export` credentials.

# Security

## Reporting

TODO before marketplace submission: replace with a monitored address.

Include the affected version, a repro that uses only fixture numbers, and impact. Do not file secrets or live call recordings in a public issue.

## Key handling

Two keys. Different homes. Telnyx cannot transcribe Dial-verb recordings, so STT is on the default path.

| Secret | Where it lives | Rule |
|---|---|---|
| Telnyx API key | Cursor **plugin variable** `TELNYX_API_KEY` | Entered under Plugins → Configure. Cursor's backend attaches it as the `Authorization` header on Telnyx MCP calls. It must not appear in the repo, in chat, or on the Bot computer. |
| xAI API key | Grok Bot **secure secret request** → env `XAI_API_KEY` | Entered once through the masked flow (excluded from chat transcript and model context). Runtime: `POST https://api.x.ai/v1/stt` (multichannel, on the recording `media_url` fetched via Telnyx MCP). Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Never a plugin variable — the MCP config does not reference it. Never pasted in chat. Never written to `.env` or disk. |

Voice Agent Builder holds its own console credentials on xAI's side; that is not a PhoneZero plugin variable. The Bot needs `XAI_API_KEY` for runtime STT and setup-time number registration.

There is no PhoneZero server and no PhoneZero-held key. Revoke at the vendor: rotate the Telnyx key in Mission Control and update the plugin variable; rotate the xAI key in the xAI console and re-enter it through the secure-secret flow.

## Blast radius

- Use a **dedicated Telnyx account** for PhoneZero. Plugins are account-wide; a shared Telnyx account shares every number and recording on that account with every Bot that can call the MCP.
- Set a **Telnyx daily spend cap** on the outbound voice profile and an **xAI spend limit** (prepaid / monthly top-up max) during setup. The skill cannot enforce spend.
- Keys are revocable at Telnyx and xAI. Treat a leaked plugin-variable value as a live credential and rotate it.

## Account-wide Bot computer

Grok Bot's computer is account-wide: all Bots on the account share files, browser sessions, and command-line credentials. Disk is the worst place for a PhoneZero secret. The Telnyx key never lands there (plugin variable, Cursor backend). The xAI key is allowed on the computer only through the masked secure-secret flow. Runtime: `POST https://api.x.ai/v1/stt`. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Do not work around this by writing `.env` files, stuffing keys into `agent-tools/`, pasting keys in chat, or asking the Bot to `export` credentials.

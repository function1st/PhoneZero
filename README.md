# PhoneZero

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

PhoneZero gives [Grok Bot](https://x.ai/news/introducing-grok-bot) a phone: ask a Bot to book a restaurant table, and a Grok voice agent dials the restaurant, negotiates with the host, and the Bot confirms the outcome back in chat. Valid outcome states are exactly `booked | unavailable | no_answer | needs_user | unknown | failed`. **Zero infrastructure** — no servers, no deployment, nothing to host. Licensed under [Apache License 2.0](LICENSE).

## Adoption

0. **Or point a Grok Bot at this repository URL** and ask it to set up phone calling — [`AGENTS.md`](AGENTS.md) routes it to the skill. Pointing a Bot at this repo is how it finds the skill. You still install the plugin from this repo URL so the Telnyx MCP and plugin variables exist. Do not export TELNYX_API_KEY onto the computer. [`docs/SETUP.md`](docs/SETUP.md) is the human walkthrough. `scripts/provision.sh` is developer-only on a personal machine that may hold keys — never here.
1. Sign up for a Telnyx account and an xAI developer account. Complete Telnyx KYC and buy one US DID.
2. Install the PhoneZero plugin from the Cursor Marketplace, **or** clone this repo and install from the repo URL until the Marketplace listing exists.
3. **Keys first.** In Plugins → Configure enter `TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `PHONEZERO_AGENT_NAME`, `PHONEZERO_DISCLOSE_AI`, and `PHONEZERO_XAI_SIP_NUMBER` (same as FROM). Enter `XAI_API_KEY` via Grok Bot's secure secret request. The Telnyx MCP works once `TELNYX_API_KEY` is saved. Leave `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` empty for now.
4. Ask Grok Bot: *"Set up phone calling."* (Or run `scripts/provision.sh` on a personal machine that may hold keys.) Copy the printed ids into `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID`.
5. Ask Grok Bot: *"Book me a table for 2 at Joe's Pizza Friday around 7."*

## Architecture

Two hosted platforms provide every runtime piece; PhoneZero itself is a skill, prompts, and config.

```
Me: "Book Joe's Pizza, Friday 7pm, party of 2"
  ▼
Grok Bot (its own cloud computer)
  │ 1. tries online booking first (OpenTable/Resy via browser); if none:
  │ 2. presents the call plan in chat; on my yes:
  │ 3. places the call via the Telnyx hosted MCP tool
  ▼
Telnyx To = sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls  (agent answers)
  ▼
Inline Texml: <Pause/><Say>{task_brief}</Say><Dial>{restaurant}</Dial>
  ▼
Agent absorbs the spoken brief, hears ringback, then talks to the host
                  negotiates within the window · closing spoken recap
                                  ▼
Grok Bot polls for call completion, fetches recording media_url
(Telnyx MCP) → transcribes with xAI STT (POST /v1/stt, multichannel)
──▶ confirms outcome to me in chat · books my calendar if asked
```

**Verified (Aug 2026):** the full pipeline — MCP dial → agent answers → spoken brief heard verbatim → restaurant bridge → dual-channel recording → xAI STT → recording deletion — was proven end-to-end. The spoken-brief mechanic was live-verified the same day.

## Cost

| Item | Cost |
|---|---|
| Infrastructure | **$0** |
| Telnyx DID | ~$1/mo |
| Telnyx outbound + SIP leg + recording | ~$0.01/min |
| Grok voice agent audio (xAI) | $0.05–0.08/min |
| A 6-minute booking | ≈ $0.40–0.55 |

## How it works

The Bot plans the call in chat and waits for your yes. One Telnyx MCP tool call sets `To` to the xAI agent SIP URI (`sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls`). The agent answers immediately. Inline TeXML (`Texml` field; template `texml/bridge.xml`) then speaks a task brief (Telnyx TTS) and dials the restaurant. There is no hosted TeXML bin and no per-call Builder-console edit — the Builder prompt is static and the console is never touched at call time. Dual-channel recording is call-level. The agent negotiates only inside the window you approved, reads the reservation back before accepting, and ends with a spoken recap. Voicemail is handled conversationally and classified from the transcript.

Telnyx cannot transcribe Dial-verb recordings, so the default outcome path is: fetch the recording `media_url` through the same Telnyx MCP, then transcribe with xAI STT (`POST /v1/stt`, multichannel). xAI exposes no Builder call-log API; this is the transcript. The Bot extracts the outcome from that STT result. Nothing of this stack runs on a machine you operate.

The Telnyx key never lives on the Bot computer — it is a Cursor plugin variable, attached by Cursor's backend as the MCP `Authorization` header. The xAI key arrives only via Grok Bot's masked secure-secret flow. Runtime: `POST https://api.x.ai/v1/stt`. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`.

## Setup

Human-readable walkthrough of the same work the Bot automates: **[docs/SETUP.md](docs/SETUP.md)**.

## Compliance

- **Recording notice.** The voice-agent opener states that the call is on a recorded line. That is the consent-by-continuing mechanism; if the callee objects, the agent ends politely and the Bot reports `needs_user`.
- **AI disclosure.** The `automated assistant` clause is a plugin variable (`PHONEZERO_DISCLOSE_AI`) and **defaults to on**. The agent always answers truthfully if asked whether it is an AI.
- **US destinations only in v1.** Other countries unlock when a written policy exists for that jurisdiction.
- **You own compliance** in the jurisdiction of every call you place. PhoneZero does not choose the law for you.
- **Deletion is not consent.** Deleting a recording after transcription does not exempt the capture from consent laws. Real-time transcription is interception in the same all-party-consent states as storing the audio.
- **Not legal advice.** This section is a product default, not counsel. Get a lawyer before you rely on it.

## License

[Apache License 2.0](LICENSE). Copyright 2026 Function1st.

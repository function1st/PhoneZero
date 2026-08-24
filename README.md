# PhoneZero

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

PhoneZero gives [Grok Bot](https://x.ai/news/introducing-grok-bot) a phone: ask a Bot to book a restaurant table, and a Grok voice agent dials the restaurant, negotiates with the host, and the Bot confirms the outcome back in chat (`booked @ 7:15pm` / `full, offered 8:15` / `no answer`). The name is the pitch: **zero infrastructure** — no servers, no deployment, nothing to host. Licensed under [Apache License 2.0](LICENSE).

## Adoption

1. Sign up for a Telnyx account and an xAI developer account.
2. Install the PhoneZero plugin and ask Grok Bot: *"Set up phone calling."* (The Bot performs the setup on its own computer and browser.)
3. Ask Grok Bot: *"Book me a table for 2 at Joe's Pizza Friday around 7."*

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
Telnyx dials restaurant (recorded, AMD on) ──(answered)──▶
TeXML Bin bridges the call to sip:{number}@sip.voice.x.ai
                                  ▼
                  xAI Voice Agent (Builder-configured)
                  negotiates within the window · closing spoken recap
                                  ▼
Grok Bot polls for call completion, fetches recording media_url
(Telnyx MCP) → transcribes with xAI STT (POST /v1/stt, multichannel)
──▶ confirms outcome to me in chat · books my calendar if asked
```

## Cost

| Item | Cost |
|---|---|
| Infrastructure | **$0** |
| Telnyx DID | ~$1/mo |
| Telnyx outbound + SIP leg + recording | ~$0.01/min |
| Grok voice agent audio (xAI) | $0.05–0.08/min |
| A 6-minute booking | ≈ $0.40–0.55 |

## How it works

The Bot plans the call in chat and waits for your yes. One Telnyx MCP tool call originates the outbound leg from your DID. On answer, a static TeXML bin bridges audio to an xAI Voice Agent over SIP (`sip:{number}@sip.voice.x.ai;transport=tls`). The agent negotiates only inside the window you approved, reads the reservation back before accepting, and ends with a spoken recap.

Telnyx cannot transcribe Dial-verb recordings, so the default outcome path is: fetch the recording `media_url` through the same Telnyx MCP, then transcribe with xAI STT (`POST /v1/stt`, multichannel). xAI exposes no Builder call-log API; this is the transcript. The Bot extracts the outcome from that STT result. Nothing of this stack runs on a machine you operate.

The Telnyx key never lives on the Bot computer — it is a Cursor plugin variable, attached by Cursor's backend as the MCP `Authorization` header. The xAI key arrives only via Grok Bot's masked secure-secret flow and is used solely for the one STT call per task.

## Setup

Human-readable walkthrough of the same work the Bot automates: **[docs/SETUP.md](docs/SETUP.md)**.

## Compliance

- **Recording notice.** The voice-agent opener states that the call is on a recorded line. That is the consent-by-continuing mechanism; if the callee objects, the agent ends politely and the Bot reports `needs_user`.
- **AI disclosure.** The `automated assistant` clause is a plugin variable (`PHONEZERO_DISCLOSE_AI`) and **defaults to on**. The agent always answers truthfully if asked whether it is an AI.
- **US-only default.** v1 calling is US destinations only. Other countries unlock when a written policy exists for that jurisdiction.
- **You own compliance** in the jurisdiction of every call you place. PhoneZero does not choose the law for you.
- **Deletion is not consent.** Deleting a recording after transcription does not exempt the capture from consent laws. Real-time transcription is interception in the same all-party-consent states as storing the audio.
- **Not legal advice.** This section is a product default, not counsel. Get a lawyer before you rely on it.

## Prior art

Patterns adopted: plan-first confirmation before any dial; listen-first pickup and graceful hangup; fail-closed skill rules (vague task → no call).

| Project | What it is | Difference |
|---|---|---|
| [CALL-E](https://www.heycall-e.com/) | Hosted agent-agnostic call service (MCP `plan_call` / `run_call` / `get_call_run`) | Hosted middleman. PhoneZero is BYO Telnyx + xAI; audio and transcripts stay on your accounts. |
| OpenClaw voice plugins ([voice-gpt-realtime](https://clawhub.ai/connorcallison/openclaw-voice-gpt-realtime), [voice-call-realtime](https://github.com/TristanBrotherton/openclaw-voice-call-realtime)) | Self-hosted Twilio + OpenAI-Realtime; restaurant booking, IVR, voicemail, structured outcomes | Require a server and a public tunnel. PhoneZero has no user infrastructure. |
| [dial-a-repo](https://github.com/zeke/dial-a-repo) | xAI Speech-to-Speech + Cloudflare Worker control plane | The upgrade path if you need live mid-call tools. Not the v1 default. |

## License

[Apache License 2.0](LICENSE). Copyright 2026 Function1st.

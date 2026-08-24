# PhoneHand — Implementation Plan

A phone-task capability for [Grok Bot](https://x.ai/news/introducing-grok-bot): ask a Bot to book a restaurant table, and a Grok voice agent phones the restaurant and reports back (`booked @ 7:15pm` / `full, offered 8:15` / `no answer`).

**This is a skill, not a service.** There is no server, no deployment, and no infrastructure to run. The adoption contract for a stranger is exactly:

1. Sign up for a Telnyx account and an xAI developer account.
2. Ask Grok Bot: *"Set up phone calling using the PhoneHand skill."* (The Bot performs the setup on its own computer and browser.)
3. Ask Grok Bot: *"Book me a table for 2 at Joe's Pizza Friday around 7."*

## How it works with zero servers

Two hosted platforms already provide every piece the old service designs (Azure container, then Cloudflare Worker) were building:

| Job | Old design | Now handled by |
|---|---|---|
| Voice agent session (prompt, tools, turn-taking) | Our media bridge / control WebSocket | **xAI Voice Agent Builder** — a console-configured agent answers calls on the SIP-connected number; no `realtime.call.incoming` webhook, no session code |
| Originate the restaurant call | Our orchestrator + carrier adapter | **One Telnyx REST call** from Grok Bot's own computer (`POST /v2/texml/Accounts/{sid}/Calls`) |
| Bridge restaurant ↔ voice agent | Our media relay | **Telnyx-hosted TeXML Bin** (static XML: `<Dial><Sip>sip:{number}@sip.voice.x.ai;transport=tls</Sip></Dial>`) — Telnyx bridges the answered call into xAI's SIP endpoint |
| Structured outcome | `report_outcome` tool → SQLite → SMS | **The call transcript itself**: the agent ends each call with a spoken structured recap; Grok Bot — an LLM — reads the transcript and confirms in chat. No delivery channel, no connectors, no format parsing |
| Task state, history, transcripts | SQLite / D1 | **Builder observability** (xAI console / API) — the system of record for every call |
| MCP endpoint for the Bot | Hosted MCP server | **Not needed** — the "tool" is the Bot running one `curl` from its computer, taught by `SKILL.md` |

### Per-task flow

```
Me: "Book Joe's Pizza, Friday 7pm, party of 2"
  ▼
Grok Bot (its own cloud computer)
  │ 1. looks up restaurant phone (browser)
  │ 2. POST /v2/texml/Accounts/{sid}/Calls   ← one curl, Telnyx API key from its env
  ▼
Telnyx dials restaurant ──(answered)──▶ TeXML Bin bridges to sip:{num}@sip.voice.x.ai
                                              ▼
                              xAI Voice Agent (Builder-configured)
                              talks to host · negotiates within window
                              ends with a spoken structured recap
                                              ▼
Grok Bot polls Telnyx for call completion, reads the transcript
(xAI console via its browser, or Telnyx recording + xAI STT)
──▶ confirms outcome to me in chat · books my calendar itself if asked
```

The restaurant-side audio never touches user infrastructure; Telnyx and xAI talk SIP directly.

## Architecture decisions

| Decision | Choice | Why |
|---|---|---|
| Telephony | **Telnyx** (TeXML REST + hosted TeXML Bins + direct SIP to xAI) | The only carrier work is one outbound-call REST request and a static hosted bin — no webhooks, no media streaming, no user server. Twilio equivalents (TwiML Bins) exist, so a Twilio variant is a docs PR. |
| Voice agent | **xAI Voice Agent Builder** (beta) on a SIP-connected Telnyx number | Owns the call session, prompt, guardrails, tools, recordings, and transcripts. Free provisioned number not used — the Telnyx number connects via direct SIP so *we* can originate calls on it. |
| Outcome channel | **The transcript, read by the Bot; confirmation delivered in chat.** The agent prompt requires a closing spoken recap ("Confirming: booked, Friday 7:15, party of 2, under {name}"). Two retrieval channels, both within the two accounts: (a) the Bot's browser reads the call's transcript/tool log in the xAI console (Builder stores them per call; **confirmed: no public API for Builder call history exists today** — docs.x.ai has no such endpoint and the management API covers only keys/collections/audit); (b) API-only fallback: Telnyx records leg A (dual-channel, ~$0.002/min), the Bot fetches the recording via Telnyx REST and transcribes it with xAI STT (`POST /v1/stt`, $0.10/hr, multichannel separates host and agent). If xAI later ships a call-log API, swap channel (a) to it. | No third product, no connectors, no format parsing — the reader is an LLM and the Bot reports the result **directly in the conversation**, then does any follow-through itself with its own tools (e.g. putting the reservation on my calendar). |
| Orchestrator | **Grok Bot itself**, guided by `skills/SKILL.md` | The Bot has a persistent computer, terminal, and browser. It fires the call, polls Telnyx for completion, reads the transcript, retries per policy, and reports back. Retries/scheduling use Bot routines — no queue infra. |
| Guardrails | Telnyx spend caps + xAI spend limits + skill-encoded policy (max attempts, calling hours, confirmation read-back in the agent prompt) | Nothing server-side exists to enforce caps, so the money-level backstops live in the two vendor dashboards. Acceptable for personal use; documented honestly. |
| License & naming | **Apache-2.0**, neutral name | Cursor Marketplace requires open source; avoid xAI/Telnyx trademarks in the name. |

## What ships in the repo

```
skills/phonehand/SKILL.md   the product: teaches Grok Bot setup + per-call flow
prompts/voice-agent.md      the Voice Agent Builder system prompt (paste/import)
texml/bridge.xml            the TeXML Bin content (one <Dial><Sip> bridge)
scripts/place-call.sh       the curl the Bot runs (params: to, from, bin URL)
scripts/setup-check.sh      verifies Telnyx app, bin, SIP registration, agent reachable
docs/SETUP.md               the human-readable version of what the Bot automates
docs/PLAN.md                this plan
.cursor-plugin/plugin.json  plugin manifest (variables: TELNYX_API_KEY, numbers)
```

No `service/`, no `infra/`, no database, no CI deploy pipeline. Tests shrink to: TeXML/prompt lint, a scripted persona checklist for manual eval, and `setup-check.sh`.

### One-time setup (what the skill walks the Bot through)

1. **Telnyx** (browser + API): buy a US DID (~$1/mo), create an outbound voice profile, create a TeXML application, create the hosted TeXML Bin from `texml/bridge.xml`, store the API key on the Bot's computer.
2. **xAI** (browser): in Voice Agent Builder, create the agent from `prompts/voice-agent.md`, set guardrails, and connect the Telnyx number via direct SIP. No connectors needed — outcomes come back through the transcript, and the Bot handles follow-through (chat confirmation, calendar) itself.
3. **Verify**: run `setup-check.sh`, then a test call to the user's own phone.

Steps are also documented for a human in `docs/SETUP.md` — the Bot doing it is convenience, not a requirement.

## Costs

| Item | Cost |
|---|---|
| Infrastructure | **$0** — nothing deployed |
| Telnyx DID | ~$1/mo |
| Telnyx outbound + SIP leg | ~$0.005–0.01/min |
| Grok voice agent audio | $0.05–0.08/min (xAI) |
| A 6-minute booking | ≈ $0.40–0.55 |

## Phases

### Phase 0 — Accounts & manual proof
- Telnyx signup + KYC (the slow item, first), DID, outbound voice profile. xAI account with Voice Agent Builder access.
- Prove the whole path **by hand, zero code**: console-created Builder agent + SIP-connected number + hand-made TeXML bin + one curl → the agent talks to me on my own phone. If this works, the architecture is validated end-to-end.

### Phase 1 — The calling assets
- `prompts/voice-agent.md` v1: self-identify as an AI assistant, state the ask early, negotiate only within the window, verbatim read-back before accepting, then **close every call with the spoken structured recap** ("Confirming: booked / not booked, {time}, party of {n}, under {name}"). Voicemail policy (leave callback, don't book).
- `texml/bridge.xml` with answering-machine detection on the dial; `scripts/place-call.sh`; `scripts/setup-check.sh`.
- The recap grammar spec shared by the agent prompt and the skill (what the Bot looks for in the transcript's closing lines).
- ~~Verify whether call transcripts are exposed via xAI API~~ **Resolved (Aug 2026): they are not** — no Builder call-history endpoint exists in docs.x.ai or the management API. The skill's transcript step uses the Bot's browser on the console, with the Telnyx-recording + xAI-STT path as the API-only alternative; exercise both in this phase and standardize on the sturdier one.

### Phase 2 — Call quality
- Persona eval checklist run against the Builder agent (busy host, IVR, voicemail, "we're full", counter-offer): scripted scenarios I answer myself, asserting the closing recap in the transcript is correct each time.
- Known-extension IVRs handled via TeXML `send_digits_on_answer`; document the limitation that the agent cannot press mid-call IVR digits in this architecture.
- Tune Builder guardrails; confirm transcripts/recordings land in the console.

### Phase 3 — The skill
- `skills/phonehand/SKILL.md`, drafted from real delegation transcripts: what to collect from the user before calling (window, party size, booking name, callback number), when to call vs decline (business hours, do-not-call judgment), how to fire the curl, how to poll Telnyx for call completion, how to fetch and read the transcript, retry policy (max 2 attempts, 20 min apart), and how to report back.
- Run the full loop from a Grok Bot conversation repeatedly; iterate the skill until it needs no hand-holding.

### Phase 4 — Setup automation + packaging
- Extend the skill with the guided setup flow (Bot performs Telnyx + Builder configuration in its browser; human approves each credentialed step).
- `.cursor-plugin/plugin.json` (variables: `TELNYX_API_KEY`, `PHONEHAND_FROM_NUMBER`, TeXML app/bin IDs) → submit to the Cursor Marketplace (this is the Grok Bot channel — Grok Bot uses Cursor's plugin system and policies).
- Tag a release; PR to `xai-org/plugin-marketplace` pinned to the 40-char commit SHA (Grok Build audience — same repo layout works, since Grok Build reads `.cursor-plugin/` equivalents).
- Stranger test: fresh Telnyx + xAI accounts → working test call, driven only by the skill and README.

## Open-source hygiene (from commit one — history becomes public)

- No secret ever committed; `.env.example` only; secret scanning in CI.
- No personal data in the repo: fixture numbers are `+15555550100`-style, transcripts synthetic.
- Everything parameterized (numbers, booking name, prompt) — nothing works-only-for-Bryan.
- Safety defaults that survive strangers: agent self-identifies as AI, calling-hours guard and attempt caps in the skill, recording stays inside the user's own xAI console, prominent README note that users own compliance with robocall/recording-consent law. No bulk-calling examples, ever.
- README with the 3-step adoption contract up top, architecture diagram, cost table; `SECURITY.md`, `CONTRIBUTING.md`, Apache-2.0 `LICENSE`.

## Upgrade path (documented appendix, not built now)

If someone needs hard-structured outcomes (a tool call, not a transcript read), server-enforced budgets, or mid-call custom tools, the same repo documents the control-plane upgrade: a Cloudflare Worker (free plan) receiving xAI's `realtime.call.incoming` webhook and driving the session over WebSocket with a `report_outcome` function tool — the [dial-a-repo](https://github.com/zeke/dial-a-repo) pattern. The TeXML bin and Telnyx setup are unchanged; only the xAI side switches from Builder to API. This is the escape hatch, not the default.

## Risks

| Risk | Mitigation |
|---|---|
| Voice Agent Builder is beta; features/pricing shift | Setup is thin (one agent, one prompt, one connector) — cheap to reconfigure; upgrade path documented if Builder regresses |
| Transcript missing or delayed after call end | Skill waits for Telnyx call-completion first, then polls the transcript with a timeout; treats absence as `unknown` (never `booked`) before retrying |
| Agent invents a confirmation | Prompt requires verbatim read-back before accepting; the Bot only reports `booked` when the transcript shows the host confirming the recap; full audio in console as final arbiter |
| Mid-call IVR ("press 2 for reservations") | `send_digits_on_answer` covers known extensions; otherwise documented limitation — the upgrade path restores full DTMF |
| Bot-side setup drifts (Telnyx/Builder UIs change) | `setup-check.sh` verifies the invariants (bin content, SIP registration, agent answers); docs/SETUP.md kept UI-agnostic |
| Telnyx KYC delays | Phase 0 first |
| No server-side spend enforcement | Telnyx spend cap + xAI spend limit set during setup; skill enforces attempt/hour policy |

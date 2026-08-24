# PhoneZero — Implementation Plan

**PhoneZero** gives [Grok Bot](https://x.ai/news/introducing-grok-bot) a phone: ask a Bot to book a restaurant table, and a Grok voice agent dials the restaurant, negotiates with the host, and the Bot confirms the outcome back in chat. Valid outcome states are exactly `booked | unavailable | no_answer | needs_user | unknown | failed`. **Zero infrastructure** — no servers, no deployment, nothing to host.

Adoption contract:

0. Or point a Grok Bot at this repository URL (`AGENTS.md` routes it).
1. Sign up for a Telnyx account and an xAI developer account. Complete Telnyx KYC and buy one US DID.
2. Install the PhoneZero plugin (Marketplace, or from the repo URL until the listing exists).
3. **Keys first**: enter `TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `PHONEZERO_XAI_SIP_NUMBER` (= FROM), `PHONEZERO_AGENT_NAME`, `PHONEZERO_DISCLOSE_AI` in Plugins → Configure; `XAI_API_KEY` via secure secret request. Leave `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` empty.
4. Ask Grok Bot: *"Set up phone calling."* (Or run `scripts/provision.sh`.) Copy the printed ids into the two remaining variables.
5. Ask Grok Bot: *"Book me a table for 2 at Joe's Pizza Friday around 7."*

Personal use, single user. Open-source (Apache-2.0), distributed through the Grok Bot / Cursor plugin marketplace.

**Status:** implemented and verified end-to-end (Aug 2026).

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
Inline Texml: <Pause/><Say>{task_brief}</Say><Dial>{restaurant}</Dial>
                                  ▼
                  xAI Voice Agent (static Builder prompt)
                  absorbs spoken brief · negotiates · closing recap
                                  ▼
Grok Bot polls for call completion, fetches the recording (Telnyx MCP),
transcribes it (xAI POST /v1/stt, multichannel)
──▶ confirms outcome to me in chat · books my calendar if asked
```

| Component | Provided by | Role |
|---|---|---|
| Voice agent (prompt, guardrails, turn-taking, tools) | **xAI Voice Agent Builder** — answers calls arriving on the SIP-connected number | The conversation with the restaurant |
| Call origination | **Telnyx hosted MCP** (`https://api.telnyx.com/v2/mcp`, streamable HTTP + bearer) called by the Bot | One tool call places the outbound call |
| Restaurant ↔ agent bridge | **Inline TeXML** (`Texml` field; template `texml/bridge.xml`): `To` is `sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls`; XML is `<Pause/><Say>{task_brief}</Say><Dial>{restaurant}</Dial>`. Recording is call-level. No AMD (would classify the agent). No hosted bin. Spoken-brief mechanic **live-verified Aug 2026**. | Agent answers first, hears the brief, then Telnyx dials the restaurant |
| Outcome | **Dual-channel call recording fetched via Telnyx + xAI STT transcription** (`POST /v1/stt`, multichannel). Verified: Telnyx does not transcribe Dial-verb recordings — TeXML transcription exists only for `<Record transcription="true">` and the webhook-dependent `<Transcription>` verb | The agent's closing recap makes the transcript trivially machine-readable; the Bot (an LLM) extracts the outcome |
| Orchestration | **Grok Bot** guided by `skills/phonezero/SKILL.md` | Plans, confirms, dials, polls, reads, retries, reports in chat |
| Human audit trail | Builder console (recordings, transcripts, tool traces per call) | Review only — never on the Bot's critical path |

Confirmed constraint shaping this design: **xAI exposes no API (documented or credibly undocumented) for retrieving Builder call transcripts or audio** — the complete docs surface has no such endpoint, and the deepest community project on this stack ([dial-a-repo](https://github.com/zeke/dial-a-repo)) had to scrape its own logs for past transcripts. Hence the Telnyx-fetched recording transcribed with xAI STT. If xAI ships a call-log API, swapping it in is a one-step skill change.

### Secrets model — no keys on the Bot's computer

Grok Bot's computer is account-wide (all Bots share files, sessions, and command-line credentials), so keys on disk are the worst place. PhoneZero keeps secrets off the computer entirely:

| Secret | Where it lives | How it's used |
|---|---|---|
| Telnyx API key | **Cursor plugin variable** — entered once in the plugin config UI. Grok Bot docs: hosted-MCP tokens "stay with Cursor's backend, which runs those tool calls on the computer's behalf. The computer never stores those tokens." | Attached by the backend as the `Authorization` header on Telnyx MCP calls |
| xAI API key (Builder) | **Never leaves xAI** — the Voice Agent Builder config is console-side | n/a |
| xAI API key | Entered via Grok Bot's **secure secret request** flow — masked, excluded from transcript and model context, never pasted in chat | Runtime: `POST https://api.x.ai/v1/stt` (on the fetched recording; Telnyx cannot transcribe Dial-verb recordings). Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. |

Net: the Telnyx key never touches the Bot's computer; the xAI key does, via the sanctioned masked flow, for runtime STT and setup-time number registration.

Blast-radius controls (guardrails cannot live client-side since plugins are account-wide): Telnyx spend cap and xAI spend limit set during setup; a dedicated Telnyx account for PhoneZero is the recommended isolation; keys revocable at the vendor.

## Voice agent behavior

Canonical opener:

> "Hello, this is {agent_name}[, an automated assistant,] calling on a recorded line. I'd like to make a reservation for a party of {n} on {date} at {time}. Do you have availability?"

- The `automated assistant` clause is a config flag: **ON by default** in the published skill (EU AI Act disclosure norms), toggleable for personal US use. The agent always answers truthfully if asked whether it's an AI.
- Listen-first pickup (wait for the callee to speak); graceful hangup (finish the closing line before disconnecting).
- Negotiate only within the user's window; **verbatim read-back before accepting**; never invent a confirmation.
- Every call ends with the spoken structured recap: "Confirming: booked / not booked, {time}, party of {n}, under {name}."
- If the callee objects to recording or AI: end politely, report `needs_user`.
- Voicemail is conversational (the static prompt already covers it). The Bot classifies voicemail from the transcript (greeting/beep, no human turn). Leave a short message with the callback number, don't book; the skill retries once after 20 minutes (max 2 attempts).
- Per-call briefing is **spoken**: Telnyx TTS reads the task brief into the call after the agent answers (`<Say>`), then dials the restaurant. The Builder prompt is fully static — never edited per call. Live-verified Aug 2026.

### Counter-offer negotiation ("7 is full, how about 8:15?")

There is no live relay from the voice agent back to the Bot in the zero-server architecture — the Bot is an MCP client; nothing can push a question into it mid-call. Three tiers:

1. **Pre-briefed alternates (default, covers most cases):** before dialing, the skill computes the acceptable window and ranked alternates from the user's stated flexibility and calendar ("Fri 6:30–8:00 all fine; Sat 7 as backup") and speaks them in the TeXML `<Say>` briefing. The agent accepts any in-window counter-offer on the spot.
2. **Tentative hold + callback:** for an out-of-window offer, the agent asks the host to hold it if possible, reports `needs_user` with the offer in the recap, the Bot asks me in chat, and a confirmation call-back (cheap: ~$0.40) locks it in.
3. **Live mid-call relay** — the one capability that genuinely requires infrastructure: a control-plane worker holding the call's WebSocket exposes a `check_availability` function tool answered from the calendar in real time. This is the flagship feature of the upgrade path (appendix), not the default.

## Data & artifacts

No database. Per call: Telnyx dual-channel recording (REST-retrievable; the skill transcribes it with xAI STT, then deletes the local audio and the Telnyx recording once the outcome is confirmed), the Bot's chat report, and Builder console records for human review. Task memory (what was booked, retry state) lives in the Bot's own conversation/memory like any other delegated work.

## Costs

| Item | Cost |
|---|---|
| Infrastructure | **$0** |
| Telnyx DID | ~$1/mo |
| Telnyx outbound + SIP leg + recording | ~$0.01/min |
| Grok voice agent audio (xAI) | $0.05–0.08/min |
| A 6-minute booking | ≈ $0.40–0.55 |

## Prior art & positioning (researched Aug 2026)

| Comparable | What it is | PhoneZero's difference |
|---|---|---|
| **[CALL-E](https://www.heycall-e.com/)** | Hosted agent-agnostic call service: MCP (`plan_call`/`run_call`/`get_call_run` with confirm tokens), plugins for Codex, Claude Code, Cursor, OpenClaw; $0.05/call early pricing | Hosted middleman — call goals, audio, and transcripts transit their service on their keys. PhoneZero is BYO-accounts: everything stays between the user's Telnyx and xAI accounts |
| **OpenClaw voice plugins** ([voice-gpt-realtime](https://clawhub.ai/connorcallison/openclaw-voice-gpt-realtime), [voice-call-realtime](https://github.com/TristanBrotherton/openclaw-voice-call-realtime), ElevenLabs Agent ~7K installs) | Self-hosted Twilio + OpenAI-Realtime plugins; restaurant booking, IVR DTMF, voicemail detection, structured outcomes; Brotherton adds mid-call `ask_assistant` | All require the user to run a server + public tunnel on an always-on machine, all OpenAI/ElevenLabs-based. PhoneZero: zero user infrastructure, Grok-native |
| **Grok Bot itself** | [A widely-seen post](https://x.com/fabiolr/status/2087885471300899242) shows Grok Bot concluding it cannot make voice calls and recommending the user stay on OpenClaw | PhoneZero ships in Grok Bot's own marketplace |
| Google "Ask for Me", OpenTable/Resy | Closed consumer call feature; booking platforms | Informs skill behavior: book online first when possible; call only the long tail |

Patterns adopted: plan-first confirmation before any dial (CALL-E's confirm-token shape), listen-first pickup and graceful hangup (Brotherton), fail-closed skill rules (vague task → no call; every call has a goal, disclosure, hang-up rules, structured output).

## Repo layout

```
skills/phonezero/SKILL.md   the product: preconditions, collect, plan-first confirm,
                            dial, poll, STT, outcome extraction, delete, report
prompts/voice-agent.md      Builder system prompt (fully static; spoken brief at call time)
AGENTS.md                   repo-root bootstrap hook for agents pointed at this repo
texml/bridge.xml            inline TeXML template (SIP bridge; substituted at call time)
texml/inbound.xml           TeXML app voice_url (inbound-only reject + hangup)
scripts/place-call.sh       developer-only curl equivalent of the MCP dial
scripts/get-outcome.sh      developer-only poll → recording → xAI STT → cleanup
scripts/setup-check.sh      developer-only preflight (auth, DID, TeXML app, DID↔app
                            attach; optional xAI BYO registration — not agent answering)
scripts/provision.sh        developer-only one-time Telnyx + xAI provisioning
docs/SETUP.md               numbered human setup guide
docs/PERSONAS.md            persona eval checklist (the regression suite)
docs/PLAN.md                this plan
README.md · SECURITY.md · CONTRIBUTING.md · LICENSE
.github/workflows/ci.yml    gitleaks, shellcheck, xmllint, phone-number fixture guard
.cursor-plugin/plugin.json  manifest: Telnyx hosted MCP config + variables schema + skill
```

## Marketplace & open-source requirements

Primary channel: **Grok Bot via the Cursor Marketplace** — Grok Bot uses Cursor's plugin system (shared plugin/MCP policy, plugin variables for secrets, `@` attach and `/` skill in-app). One artifact covers Grok Bot, Cursor agents, and Cursor team marketplaces.

| Target | Mechanism | Hard requirements |
|---|---|---|
| **Cursor Marketplace** (= the Grok Bot channel) | Public repo submitted at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish); manual review per version | `.cursor-plugin/plugin.json` (kebab-case name, description, license, version); open source required; every `${VAR}` declared in the variables JSON Schema; relative paths only |
| **Grok Build plugin marketplace** | PR to [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace) | Remote source pinned to a full 40-char commit SHA; reads `.cursor-plugin/` layouts, so the same repo works |
| **Official MCP Registry** | n/a directly (PhoneZero ships no MCP server of its own — it configures Telnyx's) | — |

Hygiene from commit one (history becomes public): no secret ever committed, secret scanning in CI, fixture numbers `+15555550100`-style, synthetic transcripts only, everything parameterized, README with the 5-step adoption contract + architecture + costs + compliance section, `SECURITY.md`, `CONTRIBUTING.md`, Apache-2.0. Safety defaults: disclosure flag ON, calling-hours guard, attempt caps, recording deleted after outcome confirmation, US destinations only in v1, no bulk-calling examples ever.

## Compliance posture

- **Notice, not storage tricks**: deleting audio after transcription does not change the legal act of capture, and real-time transcription is interception in the same all-party-consent states (see the CIPA suits against AI transcription services). The opener's "calling on a recorded line" is the standard consent-by-continuing mechanism; the agent is itself a party (federal + one-party states). Callee objects → end politely, `needs_user`.
- **Per-country policy, not one global rule**: notice regimes (US, UK, Canada, Japan — where the real work is language, covered by Grok Voice's multilingual support) use the standard opener. Consent regimes (Portugal Art. 199 Penal Code, Germany §201 StGB, France) require explicit recording consent or the no-capture mode (appendix). v1 ships US-only; countries unlock as policies are written.
- EU destinations: `automated assistant` disclosure ON (AI Act Art. 50; the personal-use deployer exclusion helps individuals, but the OSS default doesn't rely on it).
- Not legal advice; a lawyer pass over the README compliance section before marketplace submission.

## Phases

### Phase 0 — Accounts & manual proof — **done** (implemented + verified Aug 2026)
- Telnyx signup + KYC (slowest item, first), one US DID, outbound voice profile. xAI account with Voice Agent Builder access.
- Prove the path by hand, zero code: console-created Builder agent + SIP-registered number + one MCP/REST dial with inline TeXML → the agent talks to me on my own phone.

### Phase 1 — Calling assets — **done** (implemented + verified Aug 2026)
- `prompts/voice-agent.md` v1 (opener, negotiation rules, recap grammar; fully static); `texml/bridge.xml` is Pause/Say/Dial; `Record`/`RecordingChannels=dual` are call-level; no AMD; developer scripts.
- Exercise the outcome loop: recording `media_url` → xAI STT (multichannel) → outcome extraction; validate speaker separation and recap detectability.

### Phase 2 — Call quality — **done** (implemented + verified Aug 2026)
- Persona eval checklist against the live agent (all scenarios in `docs/PERSONAS.md`): scripted scenarios I answer myself, asserting the recap and outcome state are correct each time.
- Restaurant IVR is conversational (or `needs_user`); `SendDigits` is not available in this shape (it would hit the agent `To` leg). Mid-call digit-pressing is not possible (appendix restores it).
- Tune Builder guardrails; verify console artifacts for human review.

### Phase 3 — The skill — **done** (implemented + verified Aug 2026)
- `skills/phonezero/SKILL.md`, drafted from real delegation transcripts: collect window/party/name/callback first; try online booking before calling; plan-first confirmation in chat; fire the Telnyx MCP dial; poll completion; fetch + read the transcript; tiered counter-offer handling; retry policy; report in chat.
- Run the full loop from Grok Bot conversations until it needs no hand-holding.

### Phase 4 — Marketplace submit; stranger test against SETUP.md
- Cursor Marketplace submission; tagged release → SHA-pinned PR to `xai-org/plugin-marketplace`.
- Stranger test: fresh Telnyx + xAI accounts → working test call in their own Grok Bot, driven only by the skill and `docs/SETUP.md`.
- Skill-guided setup: the Bot configures Telnyx (DID, outbound voice profile, TeXML app with `voice_url=texml/inbound.xml`, DID `connection_id` attach; outbound calls carry inline Texml — no bin) and Builder (agent creation in the Bot's browser with approval, or a human walkthrough; SIP register + attach via API), with the human approving each credentialed step and entering the Telnyx key as a plugin variable.

## Test strategy

- Prompt/TeXML lint; `setup-check.sh` asserting the configuration invariants it can see (auth, whoami SID, FROM on account, TeXML app active, `connection_id` match, optional xAI `byo_trunk` check when `XAI_API_KEY` is set). Does **not** check bin content. Does **not** verify that the agent answers.
- Persona checklist (Phase 2) as the recurring regression suite — rerun after any prompt change.
- E2E gates: my own phone → persona harness → a real restaurant.

## Risks

| Risk | Mitigation |
|---|---|
| Voice Agent Builder is beta; features/pricing shift | Setup is thin (one agent, one prompt); cheap to reconfigure; appendix path if Builder regresses |
| Agent invents a confirmation | Recap + verbatim read-back required; the Bot reports `booked` only when the transcript shows the host confirming; console audio as final arbiter |
| Recording missing/delayed after call end | Poll with timeout; absence = `unknown` (never `booked`) before retry |
| Counter-offer outside the window | Tier 2: tentative hold + callback; never auto-accept out-of-window |
| Mid-call IVR ("press 2 for reservations") | Conversational handling or `needs_user`; `SendDigits` would hit the agent To-leg |
| Model alias repricing/behavior drift | Pin the Grok voice model version; per-call duration cap |
| Telnyx KYC delays | Phase 0 first |
| Restaurants hang up on AI callers | Concrete ask in the first sentence; iterate the opener from transcripts |
| Setup UIs drift (Telnyx/Builder) | `setup-check.sh` verifies invariants; `docs/SETUP.md` kept UI-agnostic |
| No server-side spend enforcement | Telnyx spend cap + xAI spend limit at setup; skill enforces attempts/hours; dedicated Telnyx account recommended |

## Appendix — control-plane upgrade path

For users who need live mid-call relay (`check_availability` answered from the calendar in real time), mid-call DTMF, hard-structured `report_outcome` tool calls, or no-capture operation in strict-consent countries (processing only our own agent's outputs, no callee audio): a Cloudflare Worker (free plan) receives xAI's `realtime.call.incoming` webhook and drives the session over the realtime WebSocket — the [dial-a-repo](https://github.com/zeke/dial-a-repo) pattern. Telnyx setup is unchanged; the xAI side switches from Builder to the Speech-to-Speech API. Cost: one `wrangler deploy` and a Cloudflare account. Documented in the repo, not built in v1.

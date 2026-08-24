# PhoneHand — Implementation Plan

A personal phone-task service my own Grok bot can delegate to. The bot calls a tool like `book_reservation({ restaurant_phone, window, party_size, name })`; this service dials the restaurant from a Telnyx number, a Grok voice agent talks to the host, and the structured outcome (`booked @ 7:15pm` / `full, offered 8:15` / `no answer`) comes back to the bot and to me by SMS.

Personal use only: one user, no product analytics, no multi-tenant anything, and Azure kept at near-zero idle cost.

## Architecture decision record (short form)

| Decision | Choice | Why |
|---|---|---|
| Telephony carrier | **Telnyx** (Call Control v2 + bidirectional media streaming) | API-first REST command model, ~half Twilio's per-minute cost, L16/OPUS codecs for AI audio. Isolated behind an adapter so the carrier is swappable. |
| Voice model | **xAI Grok Speech-to-Speech** (`wss://api.x.ai/v1/realtime`) | We own the WebSocket session, so we control tools and prompts. Pin an explicit model version, not `grok-voice-latest` (the alias already repriced $0.05 → $0.08/min). |
| Grok attach pattern | **Media bridge** (Telnyx stream ↔ our service ↔ Grok WS) | Full control of DTMF, barge-in, transcripts, and model swaps. SIP-to-xAI is a later simplification if wanted. |
| Agent-facing interface | **MCP server** (stdio/HTTP) + the same handlers as plain REST | The delegating Grok bot calls MCP tools; REST + bearer token covers curl/testing. One codebase, two thin frontends. |
| App stack | **TypeScript**, single Node 22 service, pnpm | One deployable: MCP/REST endpoints, Telnyx webhooks, and the media bridge in one process. No web app. |
| Persistence | **SQLite** on an Azure Files mount | Task + call + transcript history for one user does not justify a database server. |
| Infra | **One Azure Container App, scale-to-zero**, Key Vault, GHCR (free) for images, Bicep + azd | Idle cost ≈ pennies. See cold-start note below — scale-to-zero is safe because *we* originate every call. |
| Notifications | Telnyx SMS to my phone | No UI to check; outcome arrives as a text and as the tool result. |

**Why scale-to-zero works here:** the service is only busy when a task is in flight, and every call is outbound. The MCP/REST request that submits a task is what wakes the container; we dial only after the process is warm, so there is never a cold start mid-call. Telnyx webhooks and the stream WebSocket target the same (now-warm) app.

## System shape

```
Grok bot (my assistant)
   │  MCP tool call: book_reservation(...)
   ▼
┌──────────────────────────────────────────────┐
│  PhoneHand service (one Container App)       │
│  • MCP + REST endpoints (bearer auth)        │
│  • Task state machine (SQLite)               │
│  • Telnyx webhook receiver (signed)          │
│  • Media bridge: Telnyx wss ↔ Grok wss       │
└──────┬───────────────────────────┬───────────┘
       │ Call Control REST          │ wss (L16 PCM)
       ▼                            ▼
   Telnyx ──PSTN──▶ Restaurant   xAI Grok realtime
       │
       └── SMS outcome ──▶ my phone
```

### Tool surface (what the delegating bot sees)

| MCP tool | Purpose |
|---|---|
| `book_reservation({ restaurant_name, restaurant_phone, window_start, window_end, party_size, booking_name, callback_phone, notes? })` | Queue a reservation call; returns a `task_id` immediately. |
| `get_task({ task_id })` | Status, structured outcome, transcript. The bot polls or is given the final result when the task completes. |
| `cancel_task({ task_id })` | Abort a queued or in-flight call. |
| `place_call({ phone, goal, context })` | (Later) Generic escape hatch: any phone errand described in prose — "call the pharmacy and ask if the prescription is ready." Same machinery, looser prompt. |

### Voice-agent tools (inside the phone call)

| Tool | Purpose |
|---|---|
| `report_outcome({ status: booked \| unavailable \| needs_user \| no_answer, confirmed_time?, notes })` | The only way a call is marked booked. Structured outcome → SQLite → SMS → tool result. |
| `send_dtmf({ digits })` | Navigate IVRs ("press 2 for reservations"). |
| `hangup()` | End the call after reporting. |

Prompt contract: self-identify as an AI assistant calling on behalf of {name}, state the concrete ask early, negotiate only within the user's time window, read back the final time and name verbatim before accepting, never invent a confirmation.

Answering machines: Telnyx AMD on dial → short scripted voicemail with callback number → `no_answer`, one retry after 20 minutes (max 2 attempts).

## Data model (SQLite)

```
tasks: id, kind (reservation|generic), payload_json, status
  (queued|dialing|in_progress|booked|unavailable|no_answer|failed|needs_user),
  outcome_json, created_at, updated_at

calls: id, task_id, telnyx_call_control_id, grok_conversation_id,
  started_at, answered_at, ended_at, end_reason, duration_secs,
  cost_estimate_cents

transcript_events: id, call_id, ts, role (agent|callee|system|tool),
  content, tool_name?, tool_args?
```

Status transitions as a real state machine (exhaustive switch), unit-tested.

## Azure infrastructure (cost-first)

| Resource | Choice | ~Idle cost |
|---|---|---|
| Container Apps env + 1 app | Consumption, **min replicas 0**, WebSocket ingress | ~$0 idle; per-second billing only while a task runs |
| Storage account + Azure Files share | SQLite file + call recordings (if enabled) | < $1/mo |
| Key Vault | `TELNYX_API_KEY`, `TELNYX_PUBLIC_KEY`, `XAI_API_KEY`, `MCP_BEARER_TOKEN`; managed identity access | < $1/mo |
| Container registry | **GHCR (free)** instead of ACR | $0 |
| Logging | Container Apps console logs → Log Analytics free allowance; **no App Insights** | ~$0 at personal volume |

**Total idle: roughly $1–2/mo Azure + $1/mo Telnyx DID.** Per reservation-minute: ~$0.0105 Telnyx (outbound + stream) + $0.05–0.08 Grok. A 6-minute booking ≈ $0.40–0.55.

Explicitly cut from the earlier draft: Next.js web app, PostgreSQL server, ACR, App Insights, PostHog, always-on replica, staging environment. History review = `get_task` via the bot, or the SQLite file directly.

Local dev: the service runs on a laptop with Azure Dev Tunnels (or ngrok) for Telnyx webhooks/streams; SQLite is just a local file. `azd up` deploys the one app.

## Repo layout

```
service/          the one Node service (MCP + REST + webhooks + bridge)
packages/shared/  types, task state machine, zod schemas
packages/carrier/ Telnyx adapter behind a carrier-neutral interface
packages/agent/   Grok session config, prompts, tool schemas
scripts/          spike-call.ts and operational scripts
infra/            Bicep + azd (single container app + storage + key vault)
docs/             this plan, runbook
```

pnpm workspaces, Vitest, GitHub Actions → GHCR → `az containerapp update`.

## Phases

### Phase 0 — Accounts & spike
- xAI API key with realtime access; Telnyx account, verification, one US local DID (~$1/mo), Call Control application. (Telnyx KYC is the slow item — do it first.)
- **Spike** (`scripts/spike-call.ts`): outbound call to my own phone, bridge to Grok with a trivial prompt, prove two-way audio. De-risks the only hard integration before any product code.

### Phase 1 — Vertical slice
- Bridge with real audio handling (L16, barge-in, DTMF), Telnyx adapter, agent prompt v1, `report_outcome`, SQLite persistence, signed webhook handling.
- Trigger via REST; outcome + transcript in SQLite; SMS notification. Test target: a number I answer myself pretending to be a restaurant.

### Phase 2 — Call-quality hardening
- AMD + voicemail + retry policy; IVR navigation; hold-music tolerance (VAD tuning, patient no-speech timeouts); enforced read-back; per-call max duration and per-day minute caps; kill switch.
- Eval harness: scripted "restaurant host" personas (busy host, IVR, voicemail, "we're full") replayed against the agent; assert structured outcomes.

### Phase 3 — MCP surface + Azure deploy
- MCP server exposing `book_reservation` / `get_task` / `cancel_task`; bearer-auth REST for testing; register the MCP endpoint with my Grok bot.
- Bicep for the single app + storage + Key Vault; GitHub Actions deploy; webhooks pointed at the Container Apps FQDN. Verify the scale-to-zero wake path end-to-end (submit task from cold → dial succeeds).

### Phase 4 — Guardrails & generic calls
- Spend guards: hard monthly minute budget enforced in the service, alert SMS when 80% consumed.
- `place_call` generic errand tool once reservations are reliable.
- Runbook: rotating keys, checking transcripts, raising caps.

## Test strategy

- Unit: state machine, webhook signature verification, audio re-framing (20ms chunking), tool JSON schemas.
- Integration: fake Telnyx stream server (replayed `media` frames) against the real bridge with a mocked Grok WS, and the inverse with recorded Grok sessions.
- E2E (manual, gated): my own phone → persona harness → a real restaurant.

## Risks

| Risk | Mitigation |
|---|---|
| Grok reports a booking that didn't happen | `report_outcome` is the only success path; verbatim read-back required; transcripts kept |
| IVR/hold music confuses turn-taking | DTMF tool + persona harness + patient no-speech timeouts |
| Model alias repricing/behavior drift | Pin model version; per-call cost cap |
| Telnyx KYC delays | Phase 0 first |
| Restaurants hang up on AI callers | Self-identify + immediate concrete ask; iterate on the opener from transcripts |
| WebSocket drops mid-call | Grok session resumption (`conversation_id`); Telnyx stream reconnect; unrecoverable → `no_answer` + retry |
| Scale-to-zero surprise | Wake is always caused by our own inbound request before any dial; verified explicitly in Phase 3 |

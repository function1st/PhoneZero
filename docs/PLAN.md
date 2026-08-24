# TableCall — Implementation Plan

A service where a Grok voice agent phones a restaurant and books a reservation for you: you submit "Joe's Pizza, Friday 7pm, party of 2," the system dials the restaurant from our number, Grok talks to the host, and you get a confirmation (or a "they're full, offered 8:15" follow-up) by SMS and in the web UI.

## Architecture decision record (short form)

| Decision | Choice | Why |
|---|---|---|
| Telephony carrier | **Telnyx** (Call Control v2 + bidirectional media streaming) | API-first REST command model, ~half Twilio's per-minute cost, L16/OPUS codecs for AI audio, SIP trunking on the same account as a later option. Carrier isolated behind an adapter so Twilio/SignalWire is a swap, not a rewrite. |
| Voice model | **xAI Grok Speech-to-Speech** (`wss://api.x.ai/v1/realtime`) | The whole point. We own the WebSocket session (media-bridge pattern), so we control tools, prompts, and can swap models. Pin an explicit model version, not `grok-voice-latest` (the alias repriced 1.0 → 2.0, $0.05 → $0.08/min). |
| Grok attach pattern | **Media bridge** (Telnyx stream ↔ our server ↔ Grok WS), not SIP-to-xAI | SIP-to-xAI is less code but xAI owns the media session; the bridge lets us record, add conferencing later, inject DTMF handling, and swap the model. Revisit SIP once xAI's outbound story matures. |
| App stack | **TypeScript everywhere**; Next.js App Router web app; Node 22 bridge service; pnpm workspaces | Matches team preference; one language across web, API, and bridge. |
| Infra | **Azure Container Apps** (bridge + web), **Azure Database for PostgreSQL Flexible Server**, **Key Vault**, **ACR**, **Log Analytics/App Insights**, deployed via **Bicep + azd** | Container Apps handles long-lived WebSockets and scales; Key Vault + managed identity keeps Telnyx/xAI keys out of env files. |
| Product analytics | PostHog (existing account) | Already in use; track funnel: request → dial → answered → conversation → booked. |

## System components

```
┌──────────────┐     HTTPS      ┌──────────────────────┐
│  Next.js web │ ─────────────▶ │  Orchestrator API     │
│  (request UI,│ ◀───SSE─────── │  (Next.js route       │
│  transcript) │                │  handlers)            │
└──────────────┘                └──────┬───────────────┘
                                       │ REST (create call, state)
                              ┌────────▼────────┐
                              │  Postgres        │◀─── reservation + call records
                              └────────▲────────┘
                                       │
┌──────────────┐   webhooks    ┌──────┴───────────────┐   wss    ┌─────────────┐
│   Telnyx     │ ─────────────▶│  Bridge service       │◀────────▶│  xAI Grok    │
│  (PSTN leg)  │◀──wss stream─▶│  (Node, ws)           │          │  realtime    │
└──────┬───────┘               └──────────────────────┘          └─────────────┘
       │ audio
┌──────▼───────┐
│  Restaurant  │
└──────────────┘
```

1. **Web app** (`apps/web`) — Next.js App Router, Tailwind, shadcn/ui.
   - New reservation form: restaurant name + phone (or lookup), date/time window, party size, name for the booking, callback number, special requests.
   - Live call view: status timeline (queued → dialing → answered → talking → done) + streaming transcript via SSE.
   - History: past attempts, outcomes, recordings, transcripts.
2. **Orchestrator API** (Next.js route handlers, same deployable as web).
   - `POST /api/reservations` — validate, persist, kick off the call via the carrier adapter.
   - `GET /api/reservations/:id/events` — SSE stream of call status + transcript deltas (fed from Postgres LISTEN/NOTIFY or a lightweight pub/sub table).
   - `POST /api/webhooks/telnyx` — signed webhook receiver (call.initiated / answered / hangup / machine-detection events); verifies `telnyx-signature-ed25519`.
3. **Bridge service** (`services/bridge`) — the real-time core. Standalone Node process (not a serverless function; it holds two WebSockets per call for minutes).
   - Accepts Telnyx's stream WebSocket (`stream_url` points here), opens the Grok session, relays audio both ways.
   - Audio: request L16@16k from Telnyx (`stream_bidirectional_codec: "L16"`), configure Grok session for matching PCM; fall back to PCMU@8k passthrough if needed.
   - Handles Grok server events: transcript deltas (→ Postgres → SSE), function calls (below), barge-in (clear Telnyx media queue on user speech).
   - Enforces hard limits: max call duration (10 min default), max daily minutes, kill switch.
4. **Carrier adapter** (`packages/carrier`) — `createCall`, `hangup`, `sendDtmf`, `verifyWebhook` against Telnyx; interface kept Twilio-shaped so a second adapter is a drop-in.
5. **Agent definition** (`packages/agent`) — Grok session config: system prompt, voice, VAD settings, and tools.

## Agent design

System prompt contract (drafted in `packages/agent/prompts/`): identify as an AI assistant calling on behalf of {name}, state the ask early ("a table for {party} on {date} at {time}"), negotiate within a window the user set (e.g. ±45 min), read back the final time and name before accepting, never invent a confirmation.

Tools (Grok function calling):

| Tool | Purpose |
|---|---|
| `report_outcome({ status: booked \| unavailable \| needs_user \| no_answer, confirmed_time?, notes })` | The only way a call can be marked booked. Structured outcome lands in Postgres; SMS goes to the user. |
| `send_dtmf({ digits })` | Navigate IVRs ("press 2 for reservations"). Bridge relays via Telnyx DTMF command. |
| `hangup()` | Agent ends the call after the outcome is reported. |
| `escalate_to_user()` | (Phase 4+) If the host asks something out of scope, text the user and either hold or offer a callback. |

Answering-machine handling: enable Telnyx AMD on the dial; on `machine` → leave a short scripted voicemail with the callback number, mark `no_answer`, schedule one retry 20 minutes later (max 2 attempts).

## Data model (Postgres)

```
reservations: id, user_id, restaurant_name, restaurant_phone_e164,
  window_start, window_end, party_size, booking_name, callback_phone,
  special_requests, status (draft|queued|dialing|in_progress|booked|
  unavailable|no_answer|failed|needs_user), confirmed_time, outcome_notes,
  created_at, updated_at

calls: id, reservation_id, telnyx_call_control_id, telnyx_session_id,
  grok_conversation_id, started_at, answered_at, ended_at, end_reason,
  duration_secs, recording_url, cost_estimate_cents

transcript_events: id, call_id, ts, role (agent|callee|system|tool),
  content, tool_name?, tool_args?
```

Status transitions are a real state machine in `packages/shared` (exhaustive switch, no stringly-typed drift), unit-tested.

## Azure infrastructure (Bicep + azd, in `infra/`)

| Resource | SKU / notes |
|---|---|
| Resource group | `rg-tablecall-{env}` |
| Container Apps environment | Consumption; bridge app **min replicas 1** (a cold start mid-dial is a dropped call), web app can scale to zero in dev |
| Container App: `bridge` | WebSocket ingress, sticky sessions not needed (Telnyx connects per-call), CPU 0.5 / 1Gi |
| Container App: `web` | Next.js standalone output |
| Azure Container Registry | Basic |
| PostgreSQL Flexible Server | `B1ms` burstable, 32GB; private access in prod, public + firewall in dev |
| Key Vault | `TELNYX_API_KEY`, `TELNYX_PUBLIC_KEY` (webhook verify), `XAI_API_KEY`, `DATABASE_URL`; mounted via managed identity, no secrets in env files |
| Log Analytics + App Insights | Bridge emits per-call spans (dial → answer → first Grok audio → hangup) for latency debugging |

Estimated idle cost: ~$25–40/mo (mostly the always-on bridge replica + Postgres). Per reservation-minute: ~$0.0105 Telnyx (outbound + stream) + $0.05–0.08 Grok.

Local dev: `docker compose` Postgres, `azd up` for cloud, **Azure Dev Tunnels** (or ngrok) to receive Telnyx webhooks/streams against a laptop.

## Repo layout

```
apps/web/            Next.js UI + orchestrator API routes
services/bridge/     Telnyx↔Grok media bridge (Node 22, ws)
packages/shared/     types, state machine, zod schemas
packages/carrier/    Telnyx adapter behind a carrier-neutral interface
packages/agent/      Grok session config, prompts, tool schemas
infra/               Bicep modules + azd config
docs/                this plan, runbooks
```

pnpm workspaces; Vitest; Biome or ESLint+Prettier; GitHub Actions → ACR build → `az containerapp update`.

## Phases

### Phase 0 — Accounts & spike (blocker removal)
- xAI API key with realtime access; Telnyx account, L1 verification, buy one US local DID (~$1/mo), create a Call Control application.
- Azure subscription wiring: `azd init`, service principal for CI.
- **Spike script** (`scripts/spike-call.ts`): hardcoded outbound call to my own phone, bridge to Grok with a trivial prompt, prove two-way audio. This de-risks the only hard integration before any product code exists.

### Phase 1 — Vertical slice (CLI-triggered reservation call)
- Bridge service with real audio handling (L16, barge-in, DTMF passthrough), carrier adapter, agent prompt v1, `report_outcome` tool, Postgres persistence, Telnyx webhook handling with signature verification.
- Trigger via CLI/REST; transcript and outcome land in the DB. Test target: a Google Voice number we answer ourselves pretending to be a restaurant.

### Phase 2 — Call-quality hardening
- AMD + voicemail script + retry policy; IVR navigation via `send_dtmf`; hold-music tolerance (VAD tuning, no-speech timeout that waits instead of hanging up); read-back confirmation enforced in prompt; max-duration and cost caps; call recording (Telnyx recording API) stored to Azure Blob.
- An eval harness: scripted "restaurant host" personas (busy host, IVR, voicemail, "we're full") replayed against the agent; assert structured outcomes.

### Phase 3 — Azure deployment
- Bicep for the full stack, CI/CD, Key Vault + managed identity, App Insights spans, staging + prod environments. Webhooks/streams pointed at the Container Apps FQDN.

### Phase 4 — Web app
- Reservation form, live status + transcript (SSE), history with recordings, SMS notifications via Telnyx (`booked: Fri 7:15pm under "Bryan"`). Auth: single-user to start (magic link or Entra ID later); the service is personal, don't build multi-tenant yet.

### Phase 5 — Polish & guardrails
- PostHog funnel + call-outcome analytics; error tracking; runbook docs.
- Compliance posture: calls are to businesses (not consumer robocall territory) but still — agent self-identifies as an AI assistant, we honor "take me off your list," recording only with disclosure where two-party consent states require it (or disable recording by default and keep transcripts), caller ID is our real DID with the user's callback number offered verbally.
- Nice-to-haves once core works: restaurant phone lookup (Google Places API), calendar write-back (Google Calendar), multiple time-window negotiation strategies, escalate-to-user mid-call.

## Test strategy

- Unit: state machine, webhook signature verification, audio re-framing (20ms chunking), tool-call JSON schemas.
- Integration: fake Telnyx stream server (replay captured `media` frames) against the real bridge with a mocked Grok WS; and the inverse with recorded Grok sessions.
- E2E (manual, gated): call my own phone; then the Phase 2 persona harness; only then a real restaurant.

## Risks

| Risk | Mitigation |
|---|---|
| Grok confirms a booking that didn't happen | `report_outcome` is the only success path; prompt requires verbatim read-back; transcripts reviewable in UI |
| IVR/hold music confuses turn-taking | DTMF tool + persona eval harness + generous no-speech timeouts |
| `grok-voice-latest` repricing/behavior drift | Pin model version; cost cap per call |
| Telnyx KYC/number verification delays | Phase 0 does this first, before any code depends on it |
| Restaurants hang up on AI callers | Self-identify + immediately state a short, concrete ask; measure answer→conversation conversion in PostHog and iterate on the opener |
| WebSocket drops mid-call | Grok session resumption (`conversation_id` reconnect); Telnyx stream auto-reconnect; if unrecoverable, `no_answer` + retry |

# PhoneHand — Implementation Plan

A personal phone-task service my [Grok Bot](https://x.ai/news/introducing-grok-bot) teammates can delegate to. A Bot calls a tool like `book_reservation({ restaurant_phone, window, party_size, name })`; this service dials the restaurant from a Telnyx number, a Grok voice agent talks to the host, and the structured outcome (`booked @ 7:15pm` / `full, offered 8:15` / `no answer`) comes back to the Bot and to me by SMS.

**Primary consumer: Grok Bot** (the xAI + Cursor always-on teammate product, beta Aug 2026). Grok Bot uses Cursor's plugin and MCP infrastructure — plugins are enabled on the Cursor plugins surface, MCP auth is shared across Cursor + Grok Bot, and hosted MCP tokens stay with the backend. So the deliverable is a **hosted MCP endpoint + a plugin (skill + MCP config)** that installs into Grok Bot, with the same plugin working in Cursor itself for free.

Personal use only: one user, no product analytics, no multi-tenant anything, and Azure kept at near-zero idle cost.

## Architecture decision record (short form)

| Decision | Choice | Why |
|---|---|---|
| Telephony carrier | **Telnyx** (Call Control v2 + bidirectional media streaming) | API-first REST command model, ~half Twilio's per-minute cost, L16/OPUS codecs for AI audio. Isolated behind an adapter so the carrier is swappable. |
| Voice model | **xAI Grok Speech-to-Speech** (`wss://api.x.ai/v1/realtime`) | We own the WebSocket session, so we control tools and prompts. Pin an explicit model version, not `grok-voice-latest` (the alias already repriced $0.05 → $0.08/min). |
| Grok attach pattern | **Media bridge** (Telnyx stream ↔ our service ↔ Grok WS) | Full control of DTMF, barge-in, transcripts, and model swaps. SIP-to-xAI is a later simplification if wanted. |
| Agent-facing interface | **Remote MCP server (streamable HTTP + bearer header) as the primary transport**; stdio for local dev; same handlers as plain REST for curl/testing | Grok Bot connects to custom MCP servers by URL + auth header from its Plugins surface — it runs on a cloud VM, so a local stdio package is useless to it. The hosted endpoint is the product. |
| App stack | **TypeScript**, single Node 22 service, pnpm | One deployable: MCP/REST endpoints, Telnyx webhooks, and the media bridge in one process. No web app. |
| Persistence | **SQLite** on an Azure Files mount | Task + call + transcript history for one user does not justify a database server. |
| Infra | **One Azure Container App, scale-to-zero**, Key Vault, GHCR (free) for images, Bicep + azd | Idle cost ≈ pennies. See cold-start note below — scale-to-zero is safe because *we* originate every call. |
| Notifications | Telnyx SMS to my phone | No UI to check; outcome arrives as a text and as the tool result. |
| License & naming | **Apache-2.0**, neutral project name (no "Grok"/"Telnyx" in the name) | Repo will be published as an open-source reference (Cursor Marketplace requires open source). Apache-2.0 adds a patent grant over MIT. Avoid xAI/Telnyx trademarks in the project name; describe compatibility in prose instead. |

**Why scale-to-zero works here:** the service is only busy when a task is in flight, and every call is outbound. The MCP/REST request that submits a task is what wakes the container; we dial only after the process is warm, so there is never a cold start mid-call. Telnyx webhooks and the stream WebSocket target the same (now-warm) app.

## System shape

```
Grok Bot (cloud teammate)          Cursor agent (same plugin)
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
service/            the one Node service (MCP + REST + webhooks + bridge)
packages/shared/    types, task state machine, zod schemas
packages/carrier/   Telnyx adapter behind a carrier-neutral interface
packages/agent/     Grok session config, prompts, tool schemas
scripts/            spike-call.ts and operational scripts
infra/              Bicep + azd (single container app + storage + key vault)
docs/               this plan, runbook, self-hosting guide
.cursor-plugin/     plugin.json (Cursor Marketplace manifest + variables schema)
skills/             SKILL.md teaching an agent when/how to delegate phone tasks
.mcp.json           MCP server config (Grok Build plugin layout)
server.json         MCP Registry metadata (name matches package.json mcpName)
```

pnpm workspaces, Vitest, GitHub Actions → GHCR → `az containerapp update`.

## Open-source & marketplace readiness (decided upfront, cheap now, expensive later)

**Grok Bot is the primary target, and its distribution channel is the Cursor plugin system.** Per xAI's docs: Grok Bot follows the team's existing Cursor plugin and MCP policy (no separate Grok Bot plugin controls), plugins are enabled on the Cursor plugins page with secrets entered as plugin variables, MCP authentication is shared across Cursor + Grok Bot, and eligible plans include a "team marketplace for skills and plugins." In-app, a user attaches the plugin to a task with `@` and references its skill with `/`. So one artifact — a Cursor-format plugin bundling `skills/SKILL.md` + a remote MCP config — covers Grok Bot, Cursor agents, and Cursor team marketplaces simultaneously.

How a stranger adopts it (this flow drives the repo design):

1. Deploy their own PhoneHand instance (`azd up` or laptop + tunnel) with their Telnyx/xAI keys → they get an MCP URL + bearer token.
2. Install the plugin (marketplace or repo URL) and set two variables: `PHONEHAND_MCP_URL`, `PHONEHAND_MCP_TOKEN`. The plugin's `mcp.json` uses `${VAR}` interpolation, so no fork is needed.
3. Their Bots now have `book_reservation` / `get_task` / `cancel_task` plus a skill that teaches when and how to use them.

Distribution targets and their hard requirements:

| Target | Mechanism | Hard requirements |
|---|---|---|
| **Grok Bot / Cursor Marketplace** (primary) | Public Git repo submitted at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish); manual security/quality review of every version | `.cursor-plugin/plugin.json` manifest (kebab-case name, description, license, version); **must be open source**; secrets/config declared as `variables` (JSON Schema) so users set keys in the plugin config UI, never hardcoded; every `${VAR}` in `mcp.json` declared; relative paths only. Template: [cursor/plugin-template](https://github.com/cursor/plugin-template). |
| **Grok Build Plugin Marketplace** (the terminal coding agent — adjacent audience) | PR to [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace) adding a catalog entry | Remote source pinned to a **full 40-char commit SHA** (release discipline: tag → SHA → PR); plugin layout = `skills/` + `.mcp.json` (+ optional commands/agents/hooks); Grok Build also reads `.cursor-plugin/` equivalents, so the same repo works; regenerate + validate their index scripts in the PR. |
| **Official MCP Registry** (long-tail discovery for any MCP client, incl. grok.com custom connectors) | `mcp-publisher` CLI (GitHub auth); registry hosts metadata only | For the hosted server, a `server.json` with `remotes: [{ type: "streamable-http", url }]` pointing at the user's own deployment doesn't apply — instead publish the **self-hostable npm package** with `mcpName` in `package.json` character-identical to `name` in `server.json` (`io.github.<owner>/phonehand`); versions must match exactly — automate in the release workflow. |

Upfront practices this forces (all start at commit one, because history is public later):

1. **Clean history**: no secret has ever been committed. `.env.example` only; gitleaks (or GitHub secret scanning + push protection) in CI from the first PR.
2. **No personal data in the repo**: my phone numbers, restaurant numbers, and real transcripts stay in runtime storage (SQLite/Azure Files), never in fixtures. Test fixtures use `+15555550100`-style numbers and synthetic transcripts.
3. **Everything parameterized**: caller ID, callback number, booking name, prompts, caps — env/config with zod validation and sane defaults. Nothing "works only for Bryan."
4. **BYO-keys, no shared infra**: users bring their own Telnyx + xAI keys and deploy their own instance. Ship two run modes documented equally: laptop + dev tunnel (zero cloud) and `azd up` (one command to Azure). The azd template doubles as the "deploy your own" story.
5. **Release discipline**: changesets (or similar) driving one version across `package.json`, `server.json`, and plugin manifests; git tag per release (Grok marketplace pins SHAs; MCP Registry rejects version drift); CI publishes npm + GHCR image on tag.
6. **Safety defaults that survive strangers**: this is an autodialer reference — ship with per-day call caps ON, max call duration ON, agent self-identification ON, recording OFF, and a prominent README section: users are responsible for telemarketing/robocall law (TCPA etc.) and call-recording consent in their jurisdiction. Never ship a bulk-calling example.
7. **Docs as a feature**: README with architecture diagram + cost table + 10-minute quickstart, `SECURITY.md` (reporting + key-handling notes), `CONTRIBUTING.md`, `LICENSE` (Apache-2.0), and the carrier-adapter interface documented so a Twilio adapter is an obvious community PR.
8. **The skill is part of the product**: `skills/SKILL.md` teaches a delegating Bot when to use `book_reservation` vs `place_call`, what fields to collect from the user before calling (window, party size, booking name, callback number), how to interpret outcomes, and when to escalate to the human. In Grok Bot this surfaces as the `/` skill and `@` plugin attach; the same file installs into Cursor and Grok Build. Written and versioned with the code, not bolted on at publish time.
9. **Grok Bot specifics to respect**: plugins/connectors are **account-wide** (all of a user's Bots share the computer and installed plugins) — so per-task guardrails live server-side in PhoneHand (caps, budgets), never assumed client-side; hosted-MCP tokens are held by the backend, which is another reason the bearer token must be revocable and scoped to one deployment.

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
- Remote MCP server (streamable HTTP + bearer header) exposing `book_reservation` / `get_task` / `cancel_task`; bearer-auth REST for testing.
- Bicep for the single app + storage + Key Vault; GitHub Actions deploy; webhooks pointed at the Container Apps FQDN. Verify the scale-to-zero wake path end-to-end (submit task from cold → dial succeeds).
- Connect it to my Grok Bot as a custom MCP server (Plugins surface: name + URL + auth header) and run a real delegated reservation end-to-end from a Bot conversation.
- Draft `skills/SKILL.md` now, from watching how the Bot actually uses the tools — the skill is informed by real delegation transcripts, not written cold at publish time.

### Phase 4 — Guardrails & generic calls
- Spend guards: hard monthly minute budget enforced in the service, alert SMS when 80% consumed.
- `place_call` generic errand tool once reservations are reliable.
- Runbook: rotating keys, checking transcripts, raising caps.

### Phase 5 — Publish as open-source reference
- README polish (quickstart, architecture, cost table, legal notes), `SECURITY.md`, `CONTRIBUTING.md`, sample synthetic call recording/transcript for the README.
- Finalize the plugin: `.cursor-plugin/plugin.json` with variables schema (`PHONEHAND_MCP_URL`, `PHONEHAND_MCP_TOKEN`), `skills/SKILL.md`, `mcp.json` with `${VAR}` interpolation → submit at cursor.com/marketplace/publish (this is the Grok Bot channel).
- Tag a release; PR to `xai-org/plugin-marketplace` pinned to that SHA (Grok Build audience).
- npm publish of the self-hostable server package; `server.json` + `mcp-publisher` → official MCP Registry (long-tail MCP clients, incl. grok.com custom connectors).
- Stranger test: someone with fresh Telnyx/xAI accounts gets from README → deployed instance → plugin installed in their own Grok Bot → working test call, with no help.

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

---
name: phonezero-runtime
description: PhoneZero call runtime — setup, plan-first dial, Telnyx poll, xAI STT, shared outcomes, Grok ad-hoc interview. Invoke for /setup-phone-calling, any PhoneZero outbound call, or when a phone skill hands off to dial. Do not invent a new Builder prompt.
---

# PhoneZero runtime

Shared outbound loop for every phone skill. First-party skills (`book-restaurant`, `confirm-business-hours`) and Cursor-local skills collect a task, then **hand off here** to dial. Grok Bot: if no shipped skill matches, interview into a `phonezero-task` (this file, Ad-hoc section). Do not ask Grok users to paste a `SKILL.md` or write `~/.cursor/skills`.

Destinations must be in the Telnyx outbound voice profile **PhoneZero US-only** `whitelisted_destinations` (ISO 3166-1 alpha-2). Read that list via Telnyx MCP — it is **not** a PhoneZero plugin variable. Never place a call to a country not on that list. Never place bulk or multi-destination calls. Never auto-dial.

**Defaults (not compliance advice).** Destinations default `US` on a new Telnyx profile. `PHONEZERO_DISCLOSE_AI` defaults on. Every call is recorded (dual-channel); the opener says so. Spoken name defaults to PhoneZero. Task JSON is English; after pickup the voice agent speaks the answerer’s language. The person using this sample is solely responsible for complying with all applicable laws and vendor terms — see repo [DISCLAIMER.md](../../../../DISCLAIMER.md). Do not give legal guidance in chat.

**Bootstrap from repo.** `AGENTS.md` at the repo root is the hook. **Grok Bot** (pointed at `https://github.com/function1st/PhoneZero` or “set this up”): execute **Grok Bot — set this up** in `AGENTS.md` first — do not + Add the Cursor plugin. **Cursor IDE:** this file’s Setup, after the Cursor package is installed. After install or update, start a **new** conversation.

**Builder prompt is static.** Paste [`prompts/voice-agent.md`](../../prompts/voice-agent.md) as the system prompt (`{disclosure_clause}` is the only substitution). Paste [`prompts/end_call.md`](../../prompts/end_call.md) as the `end_call` tool description. Brief each call with `phonezero-task.json`. Never edit the Builder per call. Existing agents that still search `phonezero-booking.json` must be **re-pasted** (both files) before custom skills will speak correctly. If testers share a production DID, say so before they paste.

## 1. Preconditions

Before collecting a task or touching Telnyx, verify these variables are present. Read them; do not echo secrets.

| Variable | Role |
|---|---|
| `TELNYX_API_KEY` | Cursor Configure → stdio `npx @telnyx/mcp`. Grok canary (`plugins/phonezero-grok`) → `Authorization: Bearer` on `https://api.telnyx.com/v2/mcp`. Never in chat. **The check is a successful `tools/call`** (e.g. `list_api_endpoints`) — NOT the tool list. A `401` / 10009 means the key is not wired. |
| `PHONEZERO_FROM_NUMBER` | Plugin Configure card → PhoneZero xAI MCP `get_call_config` (and the Telnyx `From`). Cursor does **not** put this in the agent shell. E.164 DID. Call-create `To`: `sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`. If `get_call_config` has no From, take the DID attached to the PhoneZero TeXML app from Telnyx `list_phone_numbers`. |
| `XAI_API_KEY` | Cursor Configure → PhoneZero xAI MCP. Grok Bot: add/use that same xAI MCP (`put_task` / `put_booking` / `transcribe`); REST Bearer on `https://api.x.ai/v1` and `/v2` is fallback only. Never in chat. Never `source ~/.phonezero/env`. Must be from a team with **ZDR off**. Check: `get_call_config.xai_key_wired` then `ensure_collection`. |
| `TELNYX_ACCOUNT_SID` | **Not on the Configure card.** Telnyx MCP has **no** `whoami` tool. `invoke_api_endpoint` `list_billing_groups` → first `data[].organization_id`. Developer curl `GET /v2/whoami` is the same value. TeXML paths: `/v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/…`. |
| `PHONEZERO_TEXML_APP_ID` | **Not on the Configure card.** Resolve with Telnyx MCP: list TeXML apps, use the one named `PhoneZero`. |
| `PHONEZERO_AGENT_NAME` | Default `PhoneZero`. Spoken name in `phonezero-task.json`. Not baked into the Builder prompt. Override per call if the user wants a different name. |
| `PHONEZERO_DISCLOSE_AI` | Boolean, default `true`. Substituted once into the Builder prompt at agent creation (`{disclosure_clause}`). Also set as `disclose_ai` in each task JSON. Toggling later does **not** change the already-created agent. |
| `PHONEZERO_XAI_COLLECTION_ID` | **Not on the Configure card.** Find-or-create collection name `PhoneZero bookings`. Attach it to the Builder agent (knowledge / file search). |

Call-time required: working Telnyx MCP, working PhoneZero xAI MCP, a From number from `get_call_config` or Telnyx list. Resolve `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` **before** the call plan — not after `put_task`. SID: `invoke_api_endpoint` `list_billing_groups` `{ "jq_filter": "[.data[].organization_id] | unique" }`. TeXML id: `invoke_api_endpoint` `list_texml_applications` `{ "filter": { "friendly_name": "PhoneZero" }, "jq_filter": ".data[] | {id, friendly_name}" }`. Destinations: `invoke_api_endpoint` `list_outbound_voice_profiles` `{ "filter": { "name": { "contains": "PhoneZero" } }, "jq_filter": ".data[] | select(.name==\"PhoneZero US-only\") | {id, name, whitelisted_destinations}" }`. Spoken name / disclose come from `get_call_config` (defaults PhoneZero / true). Collection via xAI MCP `ensure_collection`.

If Telnyx MCP or xAI MCP is missing / 401s, or From cannot be resolved: **stop. Do not dial.** Tell the user to re-save Plugins → Configure and start a **new** conversation, then `/setup-phone-calling`. Never paste keys in chat. Never `source ~/.phonezero/env`. An old chat not seeing new MCP tools is not a failure.

Do not invent `{TELNYX_ACCOUNT_SID}`.

## Setup (when the user says *Set up phone calling* or runs `/setup-phone-calling`)

Human/developer mirrors: `docs/SETUP.md`, and `scripts/provision.sh` — developer-only, run on a personal machine that may hold keys, never on this computer. Never `source ~/.phonezero/env`. Telnyx account + KYC + buying the DID stay manual. Telnyx API steps go through the Telnyx MCP. xAI Files / collections / STT / phone-numbers go through the PhoneZero xAI MCP on **both** hosts. **Grok Bot:** add that stdio `xai` server if `put_task` / `put_booking` is missing (`AGENTS.md` / README). REST on `api.x.ai` is fallback only. Do not take the key from chat. **Grok must ask** spoken name and AI disclaimer ON/OFF — do not silently keep PhoneZero / true. Destination countries are the Telnyx profile whitelist; read and show them, do not ask as a PhoneZero field.

**First message, before any API call:**

```
Before we continue, you need:
- Telnyx account + KYC done
- One US number bought (that is From)
- Telnyx API key
- xAI team with Zero Data Retention (ZDR) OFF
- xAI API key from that same team
- Access to Voice Agent Builder at console.x.ai

Missing any of these? Stop and get them. Links: telnyx.com · console.x.ai · docs.x.ai/developers/faq/security
Then we fill the rest.
```

If any of those are missing, **stop**.

**Connect the Telnyx MCP.** It is not OAuth — do not click Authenticate.

- Cursor IDE: this package’s `telnyx` is stdio `npx @telnyx/mcp` with Configure `TELNYX_API_KEY`. Do not add hosted-HTTP Telnyx here (SSE GET 404 tombstone).
- Grok Bot: stop and run `AGENTS.md` **Grok Bot — set this up**. Custom HTTP MCP (`https://api.telnyx.com/v2/mcp` + Bearer in the form). Not Cursor + Add. Not Authenticate.
- Fallback (no plugin, Cursor IDE): `"telnyx": {"command":"npx","args":["-y","@telnyx/mcp"],"env":{"TELNYX_API_KEY":"${env:TELNYX_API_KEY}"}}`. Never the literal key in the file or chat.
- **Verify with a `tools/call`, never the tool count.** Call `list_api_endpoints`. If `get_call_config.from_wired` is false, take From from Telnyx `list_phone_numbers` (PhoneZero TeXML DID).

**Keys first.** Required on the Configure card: `TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `XAI_API_KEY`. **Cursor:** name / disclose already default on the card (PhoneZero / true) — the human can change them there. Destinations are **not** on the card. **Grok Bot:** name and disclose are **not** silent. Show the `AGENTS.md` call-settings card and wait. Then write those answers into Edit Values / xAI env. Read destinations from Telnyx (`list_outbound_voice_profiles` → `PhoneZero US-only` → `whitelisted_destinations`) and show them. PATCH that profile only if they ask to add/remove countries (Mission Control → Voice → Outbound voice profiles is the same setting). Account SID, TeXML app id, and collection id are **not** on the card. If Telnyx MCP or the PhoneZero xAI MCP is unwired, send the user to Plugins → Configure and a **new** conversation. Then, field-for-field:

1. `TELNYX_ACCOUNT_SID` via Telnyx MCP `invoke_api_endpoint` `list_billing_groups` (`data[].organization_id`). Do not search the catalog for `whoami`.
2. Find-or-create outbound voice profile name `PhoneZero US-only`: `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck`, `whitelisted_destinations` default `["US"]` **on create only**, `daily_spend_limit="5.00"`, `daily_spend_limit_enabled=true` (`POST /v2/outbound_voice_profiles`; any other combo → Telnyx error 10015). **This Telnyx profile is the destination enforcement** — Telnyx rejects calls outside `whitelisted_destinations`. If the profile already exists, keep its current whitelist. `PATCH` only when the user asks to add or remove countries (e.g. add `JP`). Change the same list in Telnyx Mission Control → Voice → Outbound voice profiles.
3. Find-or-create TeXML app name `PhoneZero`: `voice_url` = the public raw URL of `texml/inbound.xml` (default `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`; verify it returns HTTP 200 before writing it), `voice_method=get`, `outbound.outbound_voice_profile_id` = that profile.
4. `PATCH /v2/phone_numbers/{phone_number_id}` `{"connection_id":"<texml_app_id>"}`.
5. Register the DID with xAI (idempotent: `GET https://api.x.ai/v2/phone-numbers` first): `POST https://api.x.ai/v2/phone-numbers` `{"name":"PhoneZero","phoneNumber":"{PHONEZERO_FROM_NUMBER}","origin":"byo_trunk"}`.
6. PhoneZero xAI MCP `ensure_collection` (name `PhoneZero bookings`). A 403 mentioning Zero Data Retention means **stop** — the key's team has ZDR on. There is no sub-team override; disable ZDR or create a sibling team and use that team's key. Keep the collection id in session. Then `register_byo_number` for the From DID if `list_phone_numbers` does not already show it as `byo_trunk`.
7. Voice Agent Builder **has no create API** (`/v1/agents` is not enabled). In this Bot's browser (or walk the human) at [https://console.x.ai](https://console.x.ai), on the **same ZDR-off team** as the key:
   - Create one agent. Paste the **body** of `prompts/voice-agent.md` (it is the system prompt — no human preamble). Substitute `{disclosure_clause}` once: `, an automated assistant,` if `PHONEZERO_DISCLOSE_AI` is true, else empty. Do not substitute a spoken name. Save. Never add a per-call TASK BRIEF. Never edit the Builder prompt per call.
   - **Welcome: on**, text exactly `PhoneZero is ready!` **Caller can interrupt: on.** That line is the session-start cue so the agent runs `collections_search` for `phonezero-task.json` during the TeXML pause, before the callee greets. Empty welcome delays the search until the callee speaks. Do not put task facts in the welcome.
   - **Knowledge / file search:** attach `PhoneZero bookings`. Without this the agent invents the ask.
   - **`end_call` tool: on.** Name exactly `end_call`. Description = the full contents of [`prompts/end_call.md`](../../prompts/end_call.md) (no extra words). The system prompt uses this tool after a spoken goodbye. Do not leave hang-up off.
   - **Max duration:** at least 10 minutes if the console exposes it.
   - Guardrails if shown: stay inside `constraints`, verbatim read-back of `success`, no invented confirmation.
   - The wizard mints a **free xAI number — ignore it.** PhoneZero always bridges to `PHONEZERO_FROM_NUMBER`. Copy the `agentId`.
   - **Re-paste** [`prompts/voice-agent.md`](../../prompts/voice-agent.md) and [`prompts/end_call.md`](../../prompts/end_call.md) if the agent was created with the old reservation-only prompt. Toggling Configure does not update a baked prompt. If this DID is also used in production, say so before pasting.
8. Attach the agent to the **registered Telnyx DID**, never the wizard's number. xAI MCP `list_phone_numbers` → find YOUR DID (`origin` `byo_trunk`) → `attach_agent` with that `phone_number_id` and the Builder `agentId`. The `agentId` is visible on the wizard's number row — copy it from there, then attach it onto the DID.
9. Keep `TELNYX_ACCOUNT_SID`, the TeXML app id, and the collection id in this session. Confirm last-4 of the From number in chat. **Do not** ask the user to paste those ids into Plugins → Configure. Do not invent SIDs.

Approve each credentialed step. Never echo keys.

## 2. Bind a phone skill, then collect

Match the user ask:

- Restaurant table / `/book-table` / `/book-restaurant` → read `skills/book-restaurant/SKILL.md` and collect there.
- Confirm hours / `/confirm-business-hours` → read `skills/confirm-business-hours/SKILL.md`.
- Cursor-local folder (`~/.phonezero/skills`, `~/.cursor/skills`, project `.phonezero/skills`) → `list_phone_skills` / `get_phone_skill` or read the folder. Follow that skill’s collect.
- Grok, no match → **Ad-hoc interview** below. Do not ask them to write a skill folder.

Do not dial until the bound skill (or ad-hoc interview) has every required field. Fail closed after one clarifying turn if the task stays vague.

## 3. Plan-first confirmation

Present the plan in chat. Do not dial in the same turn as the plan. Use the skill’s plan template if it has one; otherwise:

```
Call plan
- Skill: {skill}
- Who: {callee.name}
- Number: {callee.phone}
- Goal: {goal}
- Opener ask: {opener}
- Constraints: {constraints}
- Success: {success}
- Spoken as: {agent_name}
- From: {PHONEZERO_FROM_NUMBER}
- Callback if they miss us: {callback}
- Attempt: {attempts + 1} of 2
```

Dial **only** on an explicit yes to this plan ("yes", "go ahead", "call them"). Not implied consent, not "sounds good I guess," not a new unrelated message. If they edit the plan, re-show it and wait again.

Never auto-dial. Never dial because a previous task was approved. Vague task → no call.

## 4. Calling-hours guard and attempt cap

`attempts` = completed dial attempts for this task. Starts at 0. The plan shows `Attempt {attempts + 1} of 2`. Block when `attempts >= 2`.

Place a call only when **all** of these hold:

1. **Destination country is in the Telnyx profile `whitelisted_destinations`** (already required; default `US` on a new profile).
2. **Hours — runtime hard cap plus skill policy:**
   - Hard cap: **09:00–21:00 user-local**. Never dial outside it, override or not — except the owner setup-test exception.
   - The bound skill may add a tighter window (restaurant-local hours). Honor the tighter of the two.
   - Never call a time you know the business is closed.
3. **`attempts` < 2**. Maximum two completed dial attempts. Attempts are 20 minutes apart (wall clock). A confirmation callback after an out-of-constraint hold is a **new** plan (still needs a fresh yes) and does not count against the original task's two attempts unless it is a retry of the same unanswered ask.
4. The user has explicitly approved the **current** plan.

If it is outside calling hours: state the next legal window. Do **not** wait-and-dial. When that time comes, **re-show the plan** and dial only on a fresh explicit yes.

**Owner setup-test exception.** When the user has explicitly asked for a setup or plugin test call to **their own confirmed number** (`<Dial>` is that E.164; the task JSON says this is a test and the callee is the owner): skip the 09:00–21:00 hard cap and any skill hours window. Still require the destination country to be on the Telnyx profile whitelist, a current plan, and an explicit yes. Still max two attempts. This is only for proving the dial path during development or first-time setup — never for calling a business.

Voicemail / no-answer: leave the message (the voice agent does this), increment `attempts`, wait 20 minutes, re-check hours, **re-show the plan** (`Attempt {attempts + 1} of 2`, same ask), and dial only on a fresh yes. After two completed attempts still no human (`attempts >= 2`): outcome `no_answer`. Stop.

## 5. Upload the task JSON, then dial

The Builder prompt (`prompts/voice-agent.md`) is **fully static**. `{disclosure_clause}` was substituted once at agent creation. The spoken name is **not** in the prompt — it is in `phonezero-task.json`. **Never edit the Builder prompt per call. Never open the Builder console at call time.**

Do **not** speak a Telnyx TTS brief. Build the `phonezero-task` object (skill or ad-hoc interview). Prefer xAI MCP `put_task`. `put_booking` still works: it wraps a `kind: phonezero-booking` object into `book-restaurant`. Wait until `DOCUMENT_STATUS_PROCESSED`, then dial. Replace any existing live `phonezero-task.json` / legacy `phonezero-booking.json`. **Never** overwrite or `delete_booking` a `phonezero-template-*.json`.

Envelope (no extra top-level keys except `kind`):

```json
{
  "kind": "phonezero-task",
  "skill": "{skill or custom}",
  "spoken_name": "{agent_name}",
  "disclose_ai": true,
  "callee": { "name": "{callee_name}", "phone": "{callee_e164}" },
  "callback": "{callback_phone}",
  "goal": "{goal}",
  "opener": "{opener}",
  "constraints": ["{constraint}"],
  "success": "{success}",
  "voicemail": "{voicemail}",
  "playbook": "{short playbook}",
  "facts": {}
}
```

`disclose_ai` is true when `get_call_config.disclose_ai` is true (default). `{agent_name}` is this call's spoken name (default `get_call_config.agent_name`). Keep `playbook` short — collection search truncates.

**Both hosts:** PhoneZero xAI MCP `put_task` (or `put_booking` alias). **Grok Bot:** if those tools are missing, add stdio `xai` from `plugins/phonezero/mcp.json` (secure-field env, not `${…}`) — do not say upload is impossible. Fallback: `https://api.x.ai/v1` Bearer; sequence is `putTask` / `putBooking` in `scripts/xai-mcp.mjs`. Never echo the key. If the user said xAI is already set up, do not open the Builder.

SID and TeXML id must already be in session from Setup / `AGENTS.md`. After yes: `put_task` (wait processed) then dial immediately. Do not look up `whoami` between those two.

### Dial — Telnyx hosted MCP

Use the Telnyx hosted MCP (auth is the plugin bearer; you never pass the key). The server (`https://api.telnyx.com/v2/mcp`, serverInfo `telnyx_api` v3.0.0) exposes **three generic tools**, not per-operation names: `list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`. Use these exact `endpoint_name` values.

Place call: `invoke_api_endpoint` with `endpoint_name` `calls_accounts_texml_calls` (REST equivalent: `POST /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls`).

TeXML body fields are PascalCase (`To`, `From`, `Texml`, …). `account_sid` is the MCP path param, not a TeXML body key.

JSON `args`:

```json
{
  "account_sid": "{TELNYX_ACCOUNT_SID}",
  "ApplicationSid": "{PHONEZERO_TEXML_APP_ID}",
  "To": "sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls",
  "From": "{PHONEZERO_FROM_NUMBER}",
  "Texml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Pause length=\"3\"/><Dial callerId=\"{PHONEZERO_FROM_NUMBER}\" timeout=\"60\" timeLimit=\"600\" ringTone=\"us\"><Number>{callee_phone}</Number></Dial></Response>",
  "Record": true,
  "RecordingChannels": "dual",
  "Timeout": 30,
  "TimeLimit": 600
}
```

Load [`texml/bridge.xml`](../../texml/bridge.xml), strip comments and newlines, replace `{RESTAURANT_E164}` with `{callee.phone}` and `{PHONEZERO_FROM_NUMBER}` with the DID (Dial `callerId`). That string is the `Texml` field. The same DID is also the request `To` (`sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`). Do not send `Url` — the request schema is oneOf: `Url` XOR `Texml` XOR neither. Do not set `answerOnBridge`. Do not put `<Say>` in the Texml.

**Schema lag:** `get_api_endpoint_schema` for `calls_accounts_texml_calls` does **not** list `Texml`. `invoke_api_endpoint` still passes `Texml` through. Omit `Url` and send `Texml`.

- `To` is the agent SIP URI. The agent answers first.
- `From` is exactly `PHONEZERO_FROM_NUMBER` (E.164).
- `{callee.phone}` inside `<Dial>` is E.164 only (destination country already confirmed on the Telnyx profile whitelist).
- Recording is call-level (`Record` true, `RecordingChannels` `dual`). Do not put `record` on `<Dial>`.
- Do **not** send `MachineDetection`, `AsyncAmd`, or `SendDigits`.
- `Timeout` 30 is the ring timeout waiting for the agent `To`. Do not raise it.
- `TimeLimit` 600s is the per-call duration cap. Do not raise it.

On success, store `sid` / `CallSid` as `call_sid`. On MCP/HTTP error: outcome `failed`. Do not retry in the same turn; tell the user what Telnyx returned (no secrets).

## 6. Poll for completion

Poll: `invoke_api_endpoint` with `endpoint_name` `retrieve_calls_accounts_texml_calls` and args `account_sid`, `call_sid`. The MCP schema for that name is a **list** (no `call_sid` field) and the list call can time out — still send `call_sid`; if the list hangs, treat a completed recording on `retrieve_recordings_json_calls_accounts_texml_recordings_json` as the terminal signal. Do not use `answered_by`.

| Field | Action |
|---|---|
| `status` `ringing`, `in-progress` | Keep polling. |
| `status` `completed` | Go to recordings. |
| `status` `no-answer`, `busy` | Apply §4 retry; report `no_answer` only when `attempts >= 2`. |
| `status` `failed`, `canceled` | Outcome `failed` always. Never `succeeded` / `booked`. |

Poll every 10s while live. **Call timeout:** 12 minutes from dial. If still live at 12 minutes, stop, try recordings once, and if nothing usable → `unknown` (never `succeeded`).

## 7. Recording + transcription

Telnyx does **not** transcribe Dial-verb recordings. xAI STT is the default outcome path.

1. `invoke_api_endpoint` `retrieve_recordings_json_calls_accounts_texml_recordings_json` (not the write-named twin). Poll every 15s for up to 3 minutes after call end until a completed recording with `media_url` exists. If none: `unknown`. Never `succeeded`.
2. Download the dual-channel `media_url` promptly to `/tmp` (expires ~10 minutes). Do not paste the URL in chat.
3. PhoneZero xAI MCP `transcribe` (`file_path` = the temp download). If `XAI_API_KEY` is not set on the MCP: **stop**. Re-save Configure and start a new conversation. Never ask for the key in chat. Do not classify `succeeded`.

Channel model:

- Identify the **agent** channel by the opener ONLY ("calling on a recorded line"). The rest of the opener is skill-specific (`I'd like to make a reservation` / hours ask / ad-hoc `opener`).
- Live-person confirmation = a later turn on the non-agent channel, after the opener, that satisfies the skill’s `success`.
- A mailbox greeting / beep / "leave a message" is never confirmation.
- If `channels` is missing or the opener is not unique: outcome `unknown`, never `succeeded`.

If STT fails or returns empty text: outcome `unknown`. Never `succeeded`.

## 8. Extract the outcome (runtime shell)

There is no spoken English recap. Classify from the conversation.

Shared states (exactly one): `succeeded` | `unavailable` | `no_answer` | `needs_user` | `unknown` | `failed`.

`booked` is an alias of `succeeded` for `book-restaurant` chat copy and personas.

**`succeeded` (or `booked`) only if all of these are true:**

1. Recording exists and xAI STT returned a transcript.
2. The agent channel was identified in §7.
3. A **live person** turn on the non-agent channel confirmed the read-back required by this brief’s `success` (not voicemail).
4. The confirmed facts stay inside this brief’s `constraints`.
5. `put_task` succeeded with a complete envelope. If that upload failed, never `succeeded`.

Never invent a confirmation number or a fact that is not in the transcript.

Map everything else:

| Situation | Outcome |
|---|---|
| Live person cannot meet `success` inside `constraints` | `unavailable` |
| No human (ring/no-answer/busy) or voicemail only, after retries exhausted | `no_answer` |
| Voicemail on attempt 1 of 2 | not terminal — retry per §4 |
| Offer **outside** `constraints` | `needs_user` |
| Objected to recording or to an AI caller | `needs_user` |
| Wrong number, asked a human to call back | `needs_user` |
| Task JSON upload failed or was incomplete | `unknown` |
| Missing recording/transcript, no clear confirmation or refusal | `unknown` |
| Call abandoned mid-hold | `unknown` |
| Call `status` `failed` or `canceled` | `failed` always |
| MCP/dial/API failure | `failed` |

The bound skill may add chat wording (`booked`, hours string) on top of this shell. It may not loosen the five `succeeded` gates.

## 9. Artifacts

After successful STT (and the outcome is classified / you are ready to report it):

1. **Keep** the Telnyx recording. Do not `DELETE` it. Download the presigned `media_url` to `/tmp` only. Never copy recordings into the repo.
2. **Delete** the live xAI brief (`delete_booking` with the `put_task` ids). Do **not** delete `phonezero-template-*` files.
3. Discard the `/tmp` download after STT.

Do not copy raw audio or full transcripts into chat. Quote only the live-person confirmation phrase you relied on.

## 10. Report

Report in chat, one state, concrete facts. The bound skill fills the details (`book-restaurant` may say “booked” and offer a ~90 minute calendar event). Runtime defaults:

- `succeeded` — what `success` required, plus host notes. Offer calendar only if the skill says to.
- `unavailable` — what they said.
- `no_answer` — attempts used; offer a later retry as a new plan.
- `needs_user` — the exact offer or objection; ask what to do.
- `unknown` — why. Do not claim success.
- `failed` — what broke. Do not claim success.

There is no mid-call relay. Out-of-constraint offers → `needs_user`, then a new plan if they accept.

## Ad-hoc interview (Grok Bot — no matching skill)

Do **not** ask them to paste a `SKILL.md`, clone a gist, or write a skill folder.

1. Recognize an ad-hoc voice task (e.g. “call the clinic and ask if they take new patients”).
2. Interview, fail closed. One clarifying turn if vague; stop if they still have no callee or no success condition.
3. Fill a `phonezero-task` in chat (`skill`: `custom`, or a slug they later save). `playbook` is a short ordered list.

| Ask | Lands in |
|---|---|
| Who are we calling? (name + confirm E.164) | `callee` |
| Callback if they miss us | `callback` |
| What should the voice agent try to get done? | `goal` |
| First sentence after hello (meaning, not a script to recite in every language) | `opener` |
| What may it accept without calling you back? | `constraints` |
| What must a **live person** say before we call this a win? | `success` |
| What to leave on voicemail | `voicemail` |
| Any extra facts | `facts` |
| Spoken name override | `spoken_name` |

4. Same safety as shipped skills. Show the JSON in the call plan. Dial only on yes. Classify with §8 + this brief’s `success` / `constraints`.
5. Do not open the Builder. The JSON is the shape of the call.

### Save as a template (only if they ask)

Save the **shape** (interview questions + `goal` / `opener` / `constraints` / `success` / `voicemail` / `facts` keys), not this call’s callee/date unless they say freeze those too. Pick a store and tell them where it went. No new Configure field.

1. **This chat only** if they did not ask to save.
2. **Grok persistent memory** if the host has it. Named card: slug, when to use, interview list, brief defaults.
3. **xAI collection** if memory is missing or they want a list/get next session: `put_template` → `phonezero-template-{slug}.json` in **PhoneZero bookings**. Never write over `phonezero-task.json`. Never `delete_booking` a template. Later: `list_templates` / `get_template`.
4. **Show the JSON in chat** if 2 and 3 are unavailable. Do not invent Drive/gist/home-dir writes on Grok.

Next session: search memory then templates, then interview only instance fields. Still show a plan and wait for yes.

Cursor may save a template as a local skill folder when they ask. That is not the Grok path.

## Hard rules

- No call without §1 call-time variables, a complete collect (skill or ad-hoc), an hours check, and an explicit yes to the current plan.
- No `succeeded` / `booked` unless all five gates in §8 hold.
- No secrets, no keys in chat, no non-fixture numbers written into skills or examples.
- One callee, one task, max two attempts, 20 minutes apart.
- Never edit the Builder prompt after setup. Brief each call with `phonezero-task.json`, not TeXML `<Say>` and not the Builder console.
- Never ask a Grok user to write `~/.cursor/skills` or paste a `SKILL.md` as the way to add a scenario.

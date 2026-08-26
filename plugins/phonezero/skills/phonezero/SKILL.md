---
name: phonezero
description: Book a restaurant table by phone when no online reservation exists. Invoke for restaurant reservations, calling a business to book a table, or delegating a dining phone call (OpenTable/Resy unavailable, restaurant takes reservations by phone only). Do not invoke for SMS, email booking, or bulk/multi-restaurant calling.
---

# PhoneZero

Grok Bot skill. You collect a reservation task, try online booking first, confirm a call plan in chat, then (only on explicit yes) place one outbound call through the Telnyx hosted MCP. An xAI voice agent talks to the restaurant. You poll Telnyx for the dual-channel recording, transcribe it with xAI STT, extract the outcome, delete the booking JSON file, and report in chat. Keep the Telnyx recording.

Destinations must be in the Telnyx outbound voice profile **PhoneZero US-only** `whitelisted_destinations` (ISO 3166-1 alpha-2). Read that list via Telnyx MCP — it is **not** a PhoneZero plugin variable. Never place a call to a country not on that list. Never place bulk or multi-destination calls. Never auto-dial.

**Defaults (not compliance advice).** Destinations default `US` on a new Telnyx profile. `PHONEZERO_DISCLOSE_AI` defaults on. Every call is recorded (dual-channel); the opener says so. Spoken name defaults to PhoneZero. Booking JSON is English; after pickup the voice agent speaks the answerer’s language. The person using this sample is solely responsible for complying with all applicable laws and vendor terms — see repo [DISCLAIMER.md](../../../../DISCLAIMER.md). Do not give legal guidance in chat.

**Bootstrap from repo.** `AGENTS.md` at the repo root is the hook. **Grok Bot** (pointed at `https://github.com/function1st/PhoneZero` or “set this up”): execute **Grok Bot — set this up** in `AGENTS.md` first — do not + Add the Cursor plugin. **Cursor IDE:** this file’s Setup, after the Cursor package is installed. After install or update, start a **new** conversation.

## 1. Preconditions

Before collecting a task or touching Telnyx, verify these variables are present. Read them; do not echo secrets.

| Variable | Role |
|---|---|
| `TELNYX_API_KEY` | Cursor Configure → stdio `npx @telnyx/mcp`. Grok canary (`plugins/phonezero-grok`) → `Authorization: Bearer` on `https://api.telnyx.com/v2/mcp`. Never in chat. **The check is a successful `tools/call`** (e.g. `list_api_endpoints`) — NOT the tool list. A `401` / 10009 means the key is not wired. |
| `PHONEZERO_FROM_NUMBER` | Plugin Configure card → PhoneZero xAI MCP `get_call_config` (and the Telnyx `From`). Cursor does **not** put this in the agent shell. E.164 DID. Call-create `To`: `sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`. If `get_call_config` has no From, take the DID attached to the PhoneZero TeXML app from Telnyx `list_phone_numbers`. |
| `XAI_API_KEY` | Cursor Configure → PhoneZero xAI MCP. Grok Bot: add/use that same xAI MCP (`put_booking` / `transcribe`); REST Bearer on `https://api.x.ai/v1` and `/v2` is fallback only. Never in chat. Never `source ~/.phonezero/env`. Must be from a team with **ZDR off**. Check: `get_call_config.xai_key_wired` then `ensure_collection`. |
| `TELNYX_ACCOUNT_SID` | **Not on the Configure card.** Telnyx MCP has **no** `whoami` tool. `invoke_api_endpoint` `list_billing_groups` → first `data[].organization_id`. Developer curl `GET /v2/whoami` is the same value. TeXML paths: `/v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/…`. |
| `PHONEZERO_TEXML_APP_ID` | **Not on the Configure card.** Resolve with Telnyx MCP: list TeXML apps, use the one named `PhoneZero`. |
| `PHONEZERO_AGENT_NAME` | Default `PhoneZero`. Spoken name in `phonezero-booking.json`. Not baked into the Builder prompt. Override per call if the user wants a different name. |
| `PHONEZERO_DISCLOSE_AI` | Boolean, default `true`. Substituted once into the Builder prompt at agent creation (`{disclosure_clause}`). Also set as `disclose_ai` in each booking JSON. Toggling later does **not** change the already-created agent. |
| `PHONEZERO_XAI_COLLECTION_ID` | **Not on the Configure card.** Find-or-create collection name `PhoneZero bookings`. Attach it to the Builder agent (knowledge / file search). |

Call-time required: working Telnyx MCP, working PhoneZero xAI MCP, a From number from `get_call_config` or Telnyx list. Resolve `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` **before** the call plan — not after `put_booking`. SID: `invoke_api_endpoint` `list_billing_groups` `{ "jq_filter": "[.data[].organization_id] | unique" }`. TeXML id: `invoke_api_endpoint` `list_texml_applications` `{ "filter": { "friendly_name": "PhoneZero" }, "jq_filter": ".data[] | {id, friendly_name}" }`. Destinations: `invoke_api_endpoint` `list_outbound_voice_profiles` `{ "filter": { "name": { "contains": "PhoneZero" } }, "jq_filter": ".data[] | select(.name==\"PhoneZero US-only\") | {id, name, whitelisted_destinations}" }`. Spoken name / disclose come from `get_call_config` (defaults PhoneZero / true). Collection via xAI MCP `ensure_collection`.

If Telnyx MCP or xAI MCP is missing / 401s, or From cannot be resolved: **stop. Do not dial.** Tell the user to re-save Plugins → Configure and start a **new** conversation, then `/setup-phone-calling`. Never paste keys in chat. Never `source ~/.phonezero/env`. An old chat not seeing new MCP tools is not a failure.

Do not invent `{TELNYX_ACCOUNT_SID}`.

## Setup (when the user says *Set up phone calling* or runs `/setup-phone-calling`)

Human/developer mirrors: `docs/SETUP.md`, and `scripts/provision.sh` — developer-only, run on a personal machine that may hold keys, never on this computer. Never `source ~/.phonezero/env`. Telnyx account + KYC + buying the DID stay manual. Telnyx API steps go through the Telnyx MCP. xAI Files / collections / STT / phone-numbers go through the PhoneZero xAI MCP on **both** hosts. **Grok Bot:** add that stdio `xai` server if `put_booking` is missing (`AGENTS.md` / README). REST on `api.x.ai` is fallback only. Do not take the key from chat. **Grok must ask** spoken name and AI disclaimer ON/OFF — do not silently keep PhoneZero / true. Destination countries are the Telnyx profile whitelist; read and show them, do not ask as a PhoneZero field.

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
   - Create one agent. Paste `prompts/voice-agent.md` fully substituted once (`{disclosure_clause}` = `, an automated assistant,` if `PHONEZERO_DISCLOSE_AI` is true, else empty; do not substitute a spoken name). Save. Never add a per-call TASK BRIEF.
   - **Welcome: on**, text exactly `PhoneZero is ready!` **Caller can interrupt: on.** That line is the session-start cue so the agent runs `collections_search` during the TeXML pause, before the restaurant greets. Empty welcome delays the search until the restaurant speaks. Do not put booking facts in the welcome.
   - **Knowledge / file search:** attach `PhoneZero bookings`. Without this the agent invents the reservation.
   - **`end_call` tool: on.** Name exactly `end_call`. Description exactly: `ONLY use this tool after successfully booking the reservation or confirming no available time slot can be accommodated. Be sure to verbally exchange goodbyes so you don't abruptly end the call.` The pasted prompt already uses this tool after a spoken goodbye. Do not leave hang-up off.
   - **Max duration:** at least 10 minutes if the console exposes it.
   - Guardrails if shown: in-window only, verbatim read-back, no invented confirmation.
   - The wizard mints a **free xAI number — ignore it.** PhoneZero always bridges to `PHONEZERO_FROM_NUMBER`. Copy the `agentId`.
8. Attach the agent to the **registered Telnyx DID**, never the wizard's number. xAI MCP `list_phone_numbers` → find YOUR DID (`origin` `byo_trunk`) → `attach_agent` with that `phone_number_id` and the Builder `agentId`. The `agentId` is visible on the wizard's number row — copy it from there, then attach it onto the DID.
9. Keep `TELNYX_ACCOUNT_SID`, the TeXML app id, and the collection id in this session. Confirm last-4 of the From number in chat. **Do not** ask the user to paste those ids into Plugins → Configure. Do not invent SIDs.

Approve each credentialed step. Never echo keys.

## 2. Collect before any call

Do not dial until every required field is known. Ask for missing pieces. Fail closed: if the task stays vague after one clarifying turn (no restaurant, no day, "sometime," "a place downtown"), **do not call**.

Required:

| Field | Rules |
|---|---|
| Restaurant name | As the host will recognize it. |
| Restaurant phone | E.164. If you only have a name, look the number up, show it, and get confirmation. Reject numbers whose country is not in the Telnyx **PhoneZero US-only** `whitelisted_destinations`. `+1` covers Canada and Caribbean NANP too — confirm the actual country, ask if unsure, refuse on no. |
| Date | Concrete calendar date. |
| Preferred time | The first ask. |
| Window start–end | Inclusive acceptable range on that date. Concatenate into the spoken brief `{window}` as a single string (e.g. `6:30 PM to 8:00 PM`). |
| Ranked alternates | Ordered fallback times the agent may accept without asking you. |
| Party size | Integer ≥ 1. |
| Booking name | Name on the reservation. |
| Callback phone | E.164 the agent leaves on voicemail and gives if the host asks. Default to the user's phone; confirm it. |

Optional: special requests (high-top, allergies, stroller). Pass through; do not invent. Optional spoken name (what the agent calls itself on this call). Default `PHONEZERO_AGENT_NAME`; override if the user wants a different name for this restaurant or call.

**Window and alternates.** Collect start and end, then concatenate into `{window}` for the call plan and spoken brief (e.g. start `6:30 PM` + end `8:00 PM` → `6:30 PM to 8:00 PM`). If the user said "around 7" and did not give a window, propose a default (preferred ± 30–60 minutes, e.g. `6:30 PM to 8:00 PM`) and the ranked in-window slots (e.g. 6:45, 7:15, 7:30). Confirm that proposal in the call plan — do not silently widen it.

**Calendar.** If this Bot can read the user's calendar, compute alternates as times inside the window that do not conflict (travel buffer ~30 minutes before/after existing events). Rank: preferred time first, then nearest free in-window slots. If a backup day is free and the user allowed it, list it as a lower-rank alternate and say so in the plan. If there is no calendar access, use only the user's stated flexibility.

Hold this task in conversation memory: restaurant, E.164, date, preferred time, `{window}`, ranked alternates, party, booking name, callback, special requests, spoken name (default `PHONEZERO_AGENT_NAME`), `attempts` (completed dial attempts, starts at 0), prior `call_sid`s, last outcome.

## 3. Try online booking first

Before any call plan, try to book in the Bot's own browser: OpenTable, Resy, the restaurant's site, Google Reserve. Same date, time, party, name.

- If an online path exists and succeeds: report the confirmation in chat. Offer to add it to the calendar. **Do not call.**
- If an online path exists but needs the user (login, payment, captcha you cannot complete): hand it off in chat. **Do not call** unless they explicitly want the phone path instead.
- Call only when there is no working online path.

## 4. Plan-first confirmation

Present the plan in chat. Do not dial in the same turn as the plan.

```
Call plan
- Who: {restaurant_name}
- Number: {restaurant_phone}
- Ask: party of {n} on {date} at {time}, under {booking_name}
- Window: {window}
- Alternates the agent may accept (in order): {alternates}
- Special requests: {special_requests or "none"}
- Spoken as: {agent_name}
- From: {PHONEZERO_FROM_NUMBER}
- Callback if they miss us: {callback_phone}
- Attempt: {attempts + 1} of 2
```

Dial **only** on an explicit yes to this plan ("yes", "go ahead", "call them"). Not implied consent, not "sounds good I guess," not a new unrelated message. If they edit the plan, re-show it and wait again.

Never auto-dial. Never dial because a previous task was approved. Vague task → no call.

## 5. Calling-hours guard and attempt cap

`attempts` = completed dial attempts for this task. Starts at 0. The plan shows `Attempt {attempts + 1} of 2`. Block when `attempts >= 2`.

Place a call only when **all** of these hold:

1. **Destination country is in the Telnyx profile `whitelisted_destinations`** (already required; default `US` on a new profile).
2. **Hours — one policy, no gaps:**
   - Hard cap: **09:00–21:00 user-local**. Never dial outside it, override or not.
   - Known restaurant hours: only while the restaurant is open, and still inside the hard cap.
   - Unknown restaurant hours: **10:30–20:30 restaurant-local** (if restaurant TZ is unknown, use the user's timezone).
   - Never call a time you know the restaurant is closed.
3. **`attempts` < 2** (do not dial when `attempts >= 2`). Maximum two completed dial attempts. Attempts are 20 minutes apart (wall clock). A confirmation callback after an out-of-window hold is a **new** plan (still needs a fresh yes) and does not count against the original task's two attempts unless it is a retry of the same unanswered ask.
4. The user has explicitly approved the **current** plan.

If it is outside calling hours: state the next legal window. Do **not** wait-and-dial. When that time comes, **re-show the plan** and dial only on a fresh explicit yes.

If they ask to call outside restaurant hours but still inside 09:00–21:00 user-local: that override is a **new plan** and needs a fresh yes. The 09:00–21:00 hard cap cannot be overridden for restaurant destinations.

**Owner setup-test exception.** When the user has explicitly asked for a setup or plugin test call to **their own confirmed number** (`<Dial>` is that E.164; `phonezero-booking.json` says this is a test and the callee is the owner): skip both the restaurant-hours window and the 09:00–21:00 hard cap. Still require the destination country to be on the Telnyx profile whitelist, a current plan, and an explicit yes. Still max two attempts. This is only for proving the dial path during development or first-time setup — never for calling a restaurant.

Voicemail / no-answer: leave the message (the agent does this), increment `attempts`, wait 20 minutes, re-check hours, **re-show the plan** (`Attempt {attempts + 1} of 2`, same ask), and dial only on a fresh yes. After two completed attempts still no human (`attempts >= 2`): outcome `no_answer`. Stop.

## 6. Upload the booking JSON, then dial

The Builder prompt (`prompts/voice-agent.md`) is **fully static**. `{disclosure_clause}` was substituted once at agent creation. The spoken name is **not** in the prompt — it is in `phonezero-booking.json`. **Never edit the Builder prompt per call. Never open the Builder console at call time.**

Do **not** speak a Telnyx TTS brief. Write the facts to a JSON file, upload it to xAI Files, attach it to the PhoneZero bookings collection (replace any existing `phonezero-booking.json`), wait until `DOCUMENT_STATUS_PROCESSED`, then dial. The agent loads that file via the collection.

Build this object (no extra keys):

```json
{
  "kind": "phonezero-booking",
  "spoken_name": "{agent_name}",
  "disclose_ai": true,
  "restaurant": "{restaurant_name}",
  "party": 2,
  "date": "{date}",
  "preferred_time": "{time}",
  "window": "{window}",
  "alternates": ["{alt1}", "{alt2}"],
  "booking_name": "{booking_name}",
  "callback": "{callback_phone}",
  "special_requests": "none"
}
```

`disclose_ai` is true when `get_call_config.disclose_ai` is true (default). `{agent_name}` is this call's spoken name (default `get_call_config.agent_name`).

**Both hosts:** PhoneZero xAI MCP `put_booking`. If those tools are already live, use them. **Grok Bot:** if `put_booking` is missing, add stdio `xai` from `plugins/phonezero/mcp.json` (secure-field env, not `${…}`) — do not say upload is impossible. Fallback: `https://api.x.ai/v1` Bearer; sequence is `putBooking` in `scripts/xai-mcp.mjs`. Never echo the key. If the user said xAI is already set up, do not open the Builder.

SID and TeXML id must already be in session from Setup / `AGENTS.md` step 5. After yes: `put_booking` (wait processed) then dial immediately. Do not look up `whoami` between those two.

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
  "Texml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Pause length=\"3\"/><Dial callerId=\"{PHONEZERO_FROM_NUMBER}\" timeout=\"60\" timeLimit=\"600\" ringTone=\"us\"><Number>{restaurant_phone}</Number></Dial></Response>",
  "Record": true,
  "RecordingChannels": "dual",
  "Timeout": 30,
  "TimeLimit": 600
}
```

Load `texml/bridge.xml`, strip comments and newlines, replace `{RESTAURANT_E164}` with `{restaurant_phone}` and `{PHONEZERO_FROM_NUMBER}` with the DID (Dial `callerId`). That string is the `Texml` field. The same DID is also the request `To` (`sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`). Do not send `Url` — the request schema is oneOf: `Url` XOR `Texml` XOR neither. Do not set `answerOnBridge` — the SIP To is already answered so the agent can load the booking file; that flag is for unanswered inbound legs and can skip the PSTN Dial. Do not put `<Say>` in the Texml.

**Schema lag:** `get_api_endpoint_schema` for `calls_accounts_texml_calls` does **not** list `Texml` (the MCP's OpenAPI snapshot lags the API). `invoke_api_endpoint` still passes `Texml` through and it works. Do not "correct" yourself off the schema — omit `Url` and send `Texml`.

- `To` is the agent SIP URI (`sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`). The agent answers first.
- `From` is exactly `PHONEZERO_FROM_NUMBER` (E.164).
- `{restaurant_phone}` inside `<Dial>` is E.164 only (destination country already confirmed on the Telnyx profile whitelist).
- Recording is call-level (`Record` true, `RecordingChannels` `dual`). Do not put `record` on `<Dial>`.
- Do **not** send `MachineDetection` or `AsyncAmd`. In this shape they would classify the xAI agent (the `To` leg), which is useless. Voicemail is handled conversationally by the agent and classified from the transcript (§7 / §9).
- Do **not** send `SendDigits`. It would apply to the agent `To` leg, not the restaurant. Restaurant IVR is handled conversationally or reported `needs_user`. Mid-call DTMF is not available.
- `Timeout` 30 is the ring timeout in seconds waiting for the agent `To` to answer. Do not raise it.
- `TimeLimit` 600s is the per-call duration cap. Do not raise it.

On success, store `sid` / `CallSid` as `call_sid`. On MCP/HTTP error: outcome `failed`. Do not retry in the same turn; tell the user what Telnyx returned (no secrets).

## 7. Poll for completion

Poll the same MCP: `invoke_api_endpoint` with `endpoint_name` `retrieve_calls_accounts_texml_calls` and args `account_sid`, `call_sid` (REST equivalent: `GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}`). The MCP schema for that name is a **list** (no `call_sid` field) and the list call can time out — still send `call_sid`; if the list hangs, treat a completed recording on `retrieve_recordings_json_calls_accounts_texml_recordings_json` as the terminal signal. Returns `status` and `duration`. Do not use `answered_by` — AMD is off; voicemail is classified from the transcript (agent reports leaving a message / a voicemail greeting or beep is present and no human turn → voicemail path per §5).

This endpoint is eventually consistent.

| Field | Action |
|---|---|
| `status` `ringing`, `in-progress` | Keep polling. |
| `status` `completed` | Go to recordings. |
| `status` `no-answer`, `busy` | Not a booking; apply §5 retry; report `no_answer` only when `attempts >= 2`. |
| `status` `failed`, `canceled` | Outcome `failed` always. Never `booked`. Do not override from a transcript. If a transcript exists, quote it under `failed` only. |

Poll every 10s while live. **Call timeout:** 12 minutes from dial. If still `ringing` / `in-progress` at 12 minutes, stop polling the live call, try recordings once, and if nothing usable → `unknown` (never `booked`).

## 8. Recording + transcription

Telnyx does **not** transcribe Dial-verb recordings. TeXML transcription exists only for `<Record transcription="true">` and the webhook-dependent `<Transcription>` verb. There is no post-hoc "create transcription" API. xAI STT is the default outcome path. The xAI Builder console is review-only — not on the critical path.

After a terminal call status:

1. Fetch recordings via the Telnyx MCP: `invoke_api_endpoint` with `endpoint_name` `retrieve_recordings_json_calls_accounts_texml_recordings_json` (REST equivalent: `GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}/Recordings.json`). Do **not** use `recordings_json_calls_accounts_texml_recordings_json` — that name is a write (start recording). Response: `recordings[].media_url` (S3 presigned, expires ~600s / ~10 min) and `recordings[].sid`. Poll every 15s for up to 3 minutes after call end until a completed recording with a `media_url` exists. If none: outcome `unknown`. Never `booked`.
2. Download the dual-channel `media_url` **promptly** to a temp file on this computer (the presigned URL expires in ~10 minutes; do not commit it; do not paste the URL in chat).
3. Transcribe with the PhoneZero xAI MCP `transcribe` (`file_path` = the temp download). Do not curl STT from the agent shell. If the xAI MCP errors that `XAI_API_KEY` is not set: **stop**. Re-save Configure and start a new conversation. Never ask for the key in chat. Do not classify `booked`.

5. The multichannel response includes a `channels` array (one transcript per speaker). Apply this channel model (do not over-specify channel numbers):

   - Identify the **agent** channel by the opener ONLY ("calling on a recorded line" / "I'd like to make a reservation").
   - Host confirmation = a later turn on the non-agent channel, after the opener, that accepts the time, has the party down, or answers yes to the read-back.
   - A mailbox greeting / beep / "leave a message" is never a host confirmation.
   - If `channels` is missing or the opener is not unique (neither channel, or both channels, contain the opener): outcome `unknown`, never `booked`.

If STT fails or returns empty text: outcome `unknown`. Never `booked`. You may retry the call later under §5 (absence is not a booking).

## 9. Extract the outcome

There is no spoken English recap. Classify from the conversation.

If `channels` is missing or the agent channel was not identified in §8, outcome is `unknown` — do not search merged text for a booking.

**`booked` only if all of these are true:**

1. The agent read back party, date, time, and booking name, and a **host** turn (the non-agent channel, identified in §8) confirmed — e.g. they accept the time, say they have the party down, or answer yes to that read-back.
2. The confirmed `{time}` is inside the approved window or the pre-briefed alternates.
3. Recording exists and xAI STT returned a transcript.
4. The confirming turn is not a voicemail greeting/beep/"leave a message" — a live human turn is required.
5. The uploaded booking JSON had restaurant, party, date, preferred time, window, and booking name. If that upload failed, never `booked`.

Never invent a confirmation number or a time that is not in the transcript.

Map everything else:

| Situation | Outcome |
|---|---|
| Host said they are full / no times in window or alternates | `unavailable` |
| No human (ring/no-answer/busy) or voicemail only, after retries exhausted | `no_answer` |
| Voicemail on attempt 1 of 2 | not terminal — retry per §5; do not report a final outcome yet |
| Host offered a time **outside** window/alternates | `needs_user` |
| Host objected to recording or to an AI caller | `needs_user` |
| Wrong number, not a restaurant, host asked a human to call back | `needs_user` |
| Booking JSON upload failed or was incomplete | `unknown` |
| Missing recording/transcript, no clear host confirmation or refusal | `unknown` |
| Call abandoned mid-hold, host never refused | `unknown` |
| Call `status` `failed` or `canceled` | `failed` always. Never `booked`. Quote a transcript under `failed` only. |
| MCP/dial/API failure | `failed` |

Valid outcome states (exactly one): `booked` | `unavailable` | `no_answer` | `needs_user` | `unknown` | `failed`.

## 10. Artifacts

After successful STT (and the outcome is classified / you are ready to report it):

1. **Keep** the Telnyx recording. Do not `DELETE` it. Download the presigned `media_url` to `/tmp` only (expires in ~10 minutes). Never copy recordings into the repo or the workspace. The Telnyx recording object remains.
2. **Delete** the xAI booking file (xAI MCP `delete_booking`) so the next call cannot pick up a stale JSON.
3. Discard the `/tmp` download after STT.

There is no Telnyx transcription to delete.

Do not copy raw audio or full transcripts into chat. Quote only the host confirmation phrase you relied on.

## 11. Counter-offer tiers

There is no mid-call relay to you. Three tiers:

1. **In-window / pre-briefed alternates (default).** Already in the booking JSON. The agent accepts on the spot. You report `booked` at that time (host confirmation still required).
2. **Out-of-window offer.** Agent must not accept. It asks the host to hold if possible and says goodbye. You report `needs_user`, show the offer in chat, and wait. If the user accepts, place a **confirmation callback** with a new booking JSON (narrow ask: lock the held time) and run §4–§10 again. If they decline, stop (`unavailable`) or collect a new window.
3. **Live calendar tool mid-call** — not available. Do not pretend it is.

## 12. Report and calendar

Report in chat, one state, concrete facts:

- `booked` — restaurant, date, time, party, name, any host notes. Offer to create the calendar event yourself (title, start, duration ~90 minutes unless they say otherwise, location, phone, party). Only write the calendar if they want it.
- `unavailable` — what the host said; do not call again for the same slot unless they change the window.
- `no_answer` — attempts used; offer a later retry as a new plan.
- `needs_user` — the exact offer or objection; ask what to do.
- `unknown` — why (no transcript, no clear host confirmation). Do not claim a table.
- `failed` — what broke (Telnyx status / MCP / STT error). Do not claim a table.

## Hard rules

- No call without §1 call-time variables, a complete collect, an online-booking attempt, an hours check, and an explicit yes to the current plan.
- No `booked` unless all five gates in §9 hold (recording + transcript, live host confirmation of the read-back that is not voicemail, in-window time, complete booking JSON).
- No secrets, no keys in chat, no non-fixture numbers written into skills or examples.
- One restaurant, one task, max two attempts, 20 minutes apart.
- Never edit the Builder prompt after setup. It is fully static. Brief each call with `phonezero-booking.json` in the xAI collection, not TeXML `<Say>` and not the Builder console.

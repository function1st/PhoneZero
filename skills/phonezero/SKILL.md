---
name: phonezero
description: Book a restaurant table by phone when no online reservation exists. Invoke for restaurant reservations, calling a business to book a table, or delegating a dining phone call (OpenTable/Resy unavailable, restaurant takes reservations by phone only). Do not invoke for SMS, email booking, or bulk/multi-restaurant calling.
---

# PhoneZero

Grok Bot skill. You collect a reservation task, try online booking first, confirm a call plan in chat, then (only on explicit yes) place one outbound call through the Telnyx hosted MCP. An xAI voice agent talks to the restaurant. You poll Telnyx for the dual-channel recording, transcribe it with xAI STT, extract the outcome, delete the artifacts, and report in chat.

v1 is US destinations only. Never place a call outside the United States. Never place bulk or multi-destination calls. Never auto-dial.

## 1. Preconditions

Before collecting a task or touching Telnyx, verify these variables are present. Read them; do not echo secrets.

| Variable | Role |
|---|---|
| `TELNYX_API_KEY` | Backend-held. Cursor attaches it as `Authorization: Bearer` on Telnyx hosted MCP calls (`https://api.telnyx.com/v2/mcp`). The computer never stores or prints this key. Presence of a working Telnyx MCP session is the check — do not ask the user to paste the key in chat. |
| `TELNYX_ACCOUNT_SID` | Plugin variable. Telnyx account SID in every TeXML path: `/v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/…`. |
| `PHONEZERO_FROM_NUMBER` | E.164 DID Telnyx will present as `From`. |
| `PHONEZERO_TEXML_APP_ID` | TeXML Application SID (`ApplicationSid` on the dial). |
| `PHONEZERO_XAI_SIP_NUMBER` | E.164 registered with xAI as `byo_trunk`. Substituted into the inline Texml SIP URI at call time. Usually the **same** number as `PHONEZERO_FROM_NUMBER` (one DID registered with xAI; a second number is not required). |
| `PHONEZERO_AGENT_NAME` | Spoken name in the TASK BRIEF (`{agent_name}`). |
| `PHONEZERO_DISCLOSE_AI` | Boolean, default `true`. When true, TASK BRIEF `{disclosure_clause}` is `, an automated assistant,`. When false, empty. The agent still answers truthfully if asked whether it is an AI. |
| `XAI_API_KEY` | Environment only. Entered once via Grok Bot's secure secret request flow (masked, excluded from transcripts and model context). Runtime: `POST https://api.x.ai/v1/stt`. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Never ask for it in chat. Never echo it. |

Call-time required: `TELNYX_API_KEY` (working MCP), `TELNYX_ACCOUNT_SID`, `PHONEZERO_FROM_NUMBER`, `PHONEZERO_TEXML_APP_ID`, `PHONEZERO_XAI_SIP_NUMBER`, `PHONEZERO_AGENT_NAME`, `XAI_API_KEY`. `PHONEZERO_DISCLOSE_AI` may be absent (treat as `true`).

If any call-time variable is missing, or the Telnyx MCP is disconnected / 401s: **stop. Do not dial.** Tell the user PhoneZero is not configured and that they should say *"Set up phone calling."* Then follow **Setup** below. Never paste TELNYX_API_KEY or XAI_API_KEY in chat.

- Missing `XAI_API_KEY` after plugin config: stop and start Grok Bot's **secure secret request** flow for `XAI_API_KEY`. Never ask them to paste it in chat. After it is in the environment, re-check.

Do not invent `{TELNYX_ACCOUNT_SID}`.

## Setup (when the user says *Set up phone calling*)

Human/developer mirrors: `docs/SETUP.md` and `scripts/provision.sh`. Telnyx account + KYC + buying the DID stay manual. Telnyx API steps go through the Telnyx MCP (`list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`). xAI API steps use `XAI_API_KEY` from the environment (secure-secret flow — never ask for it in chat).

**Keys first (or the MCP cannot run).** `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` are filled in *after* this recipe; they are not required to install the plugin. Confirm these are already saved: `TELNYX_API_KEY` (plugin variable — MCP works once it is saved), `PHONEZERO_FROM_NUMBER`, `PHONEZERO_AGENT_NAME`, `PHONEZERO_DISCLOSE_AI`, and `XAI_API_KEY` (env). If `TELNYX_API_KEY` is missing, send the user to Plugins → Configure. If `XAI_API_KEY` is missing, start the secure secret request. Then, field-for-field:

1. `GET /v2/whoami` → `data.organization_id` = `TELNYX_ACCOUNT_SID`.
2. Find-or-create outbound voice profile name `PhoneZero US-only`: `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck`, `whitelisted_destinations=["US"]`, `daily_spend_limit="5.00"`, `daily_spend_limit_enabled=true` (`POST /v2/outbound_voice_profiles`; any other combo → Telnyx error 10015).
3. Find-or-create TeXML app name `PhoneZero`: `voice_url` = the public raw URL of `texml/inbound.xml` (default `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`; verify it returns HTTP 200 before writing it — until that file is on `main`, use the user's fork/branch raw URL), `voice_method=get`, `outbound.outbound_voice_profile_id` = that profile.
4. `PATCH /v2/phone_numbers/{phone_number_id}` `{"connection_id":"<texml_app_id>"}`.
5. Register the DID with xAI (idempotent: `GET https://api.x.ai/v2/phone-numbers` first): `POST https://api.x.ai/v2/phone-numbers` `{"name":"PhoneZero","phoneNumber":"{PHONEZERO_FROM_NUMBER}","origin":"byo_trunk"}`.
6. Voice Agent Builder **agent creation is console-only** (`/v1/agents` is not enabled). Walk the user through creating one agent from `prompts/voice-agent.md`, then read the `agentId` back from the Builder console (or from `GET /v2/phone-numbers` after attach).
7. Attach the agent: `PATCH https://api.x.ai/v2/phone-numbers/{phoneNumberId}` `{"phoneNumber":{"agentId":"agent_…"},"fieldMask":{"paths":["agent_id"]}}` — never a flat `{agentId}` (rejected).
8. Print the ids and have the user enter the remaining plugin variables: `TELNYX_ACCOUNT_SID`, `PHONEZERO_TEXML_APP_ID`, `PHONEZERO_XAI_SIP_NUMBER` (= `PHONEZERO_FROM_NUMBER`). Do not invent SIDs.

Approve each credentialed step. Never echo keys.

## 2. Collect before any call

Do not dial until every required field is known. Ask for missing pieces. Fail closed: if the task stays vague after one clarifying turn (no restaurant, no day, "sometime," "a place downtown"), **do not call**.

Required:

| Field | Rules |
|---|---|
| Restaurant name | As the host will recognize it. |
| Restaurant phone | E.164 (`+1…`). If you only have a name, look the number up, show it, and get confirmation. Reject non-US numbers. `+1` numbers include Canada and Caribbean NANP — confirm the destination is in the United States; if unsure, ask, and refuse on no. |
| Date | Concrete calendar date. |
| Preferred time | The first ask. |
| Window start–end | Inclusive acceptable range on that date. Concatenate into the TASK BRIEF `{window}` as a single string (e.g. `6:30 PM to 8:00 PM`). |
| Ranked alternates | Ordered fallback times the agent may accept without asking you. |
| Party size | Integer ≥ 1. |
| Booking name | Name on the reservation. |
| Callback phone | E.164 the agent leaves on voicemail and gives if the host asks. Default to the user's phone; confirm it. |

Optional: special requests (high-top, allergies, stroller). Pass through; do not invent.

**Window and alternates.** Collect start and end, then concatenate into `{window}` for the call plan and TASK BRIEF (e.g. start `6:30 PM` + end `8:00 PM` → `6:30 PM to 8:00 PM`). If the user said "around 7" and did not give a window, propose a default (preferred ± 30–60 minutes, e.g. `6:30 PM to 8:00 PM`) and the ranked in-window slots (e.g. 6:45, 7:15, 7:30). Confirm that proposal in the call plan — do not silently widen it.

**Calendar.** If this Bot can read the user's calendar, compute alternates as times inside the window that do not conflict (travel buffer ~30 minutes before/after existing events). Rank: preferred time first, then nearest free in-window slots. If a backup day is free and the user allowed it, list it as a lower-rank alternate and say so in the plan. If there is no calendar access, use only the user's stated flexibility.

Hold this task in conversation memory: restaurant, E.164, date, preferred time, `{window}`, ranked alternates, party, booking name, callback, special requests, `attempts` (completed dial attempts, starts at 0), prior `call_sid`s, last outcome.

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
- From: {PHONEZERO_FROM_NUMBER}
- Callback if they miss us: {callback_phone}
- Attempt: {attempts + 1} of 2
```

Dial **only** on an explicit yes to this plan ("yes", "go ahead", "call them"). Not implied consent, not "sounds good I guess," not a new unrelated message. If they edit the plan, re-show it and wait again.

Never auto-dial. Never dial because a previous task was approved. Vague task → no call.

## 5. Calling-hours guard and attempt cap

`attempts` = completed dial attempts for this task. Starts at 0. The plan shows `Attempt {attempts + 1} of 2`. Block when `attempts >= 2`.

Place a call only when **all** of these hold:

1. **US destination** (already required).
2. **Hours — one policy, no gaps:**
   - Hard cap: **09:00–21:00 user-local**. Never dial outside it, override or not.
   - Known restaurant hours: only while the restaurant is open, and still inside the hard cap.
   - Unknown restaurant hours: **10:30–20:30 restaurant-local** (if restaurant TZ is unknown, use the user's timezone).
   - Never call a time you know the restaurant is closed.
3. **`attempts` < 2** (do not dial when `attempts >= 2`). Maximum two completed dial attempts. Attempts are 20 minutes apart (wall clock). A confirmation callback after an out-of-window hold is a **new** plan (still needs a fresh yes) and does not count against the original task's two attempts unless it is a retry of the same unanswered ask.
4. The user has explicitly approved the **current** plan.

If it is outside calling hours: state the next legal window. Do **not** wait-and-dial. When that time comes, **re-show the plan** and dial only on a fresh explicit yes.

If they ask to call outside restaurant hours but still inside 09:00–21:00 user-local: that override is a **new plan** and needs a fresh yes. The 09:00–21:00 hard cap cannot be overridden.

Voicemail / no-answer: leave the message (the agent does this), increment `attempts`, wait 20 minutes, re-check hours, **re-show the plan** (`Attempt {attempts + 1} of 2`, same ask), and dial only on a fresh yes. After two completed attempts still no human (`attempts >= 2`): outcome `no_answer`. Stop.

## 6. Brief the voice agent, then dial

`prompts/voice-agent.md` has two sections:

- **STATIC BEHAVIOR** — loaded once at setup. Never edit this section per call.
- **TASK BRIEF** — the only block you replace. In the Voice Agent Builder console, substitute this call's values into the TASK BRIEF delimited block and replace that block only. Do not dial with a stale brief from a prior restaurant or window.

`{agent_name}` is `PHONEZERO_AGENT_NAME`. `PHONEZERO_DISCLOSE_AI` defaults `true` → `{disclosure_clause}` = `, an automated assistant,`. If `false`, `{disclosure_clause}` is empty. The agent still answers truthfully if asked whether it is an AI. EU destinations are out of v1 scope.

### Dial — Telnyx hosted MCP

Use the Telnyx hosted MCP (auth is the plugin bearer; you never pass the key). The server (`https://api.telnyx.com/v2/mcp`, streamable HTTP, serverInfo `telnyx_api` v3.0.0) exposes **three generic tools**, not per-operation names: `list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`. Use these exact `endpoint_name` values.

Place call: `invoke_api_endpoint` with `endpoint_name` `calls_accounts_texml_calls` (REST equivalent: `POST /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls`).

TeXML body fields are PascalCase (`To`, `From`, `Texml`, …). `account_sid` is the MCP path param, not a TeXML body key.

JSON `args`:

```json
{
  "account_sid": "{TELNYX_ACCOUNT_SID}",
  "ApplicationSid": "{PHONEZERO_TEXML_APP_ID}",
  "To": "{restaurant_phone}",
  "From": "{PHONEZERO_FROM_NUMBER}",
  "Texml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Dial answerOnBridge=\"true\" timeLimit=\"600\"><Sip>sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls</Sip></Dial></Response>",
  "Record": true,
  "RecordingChannels": "dual",
  "MachineDetection": "Enable",
  "AsyncAmd": true,
  "Timeout": 30,
  "TimeLimit": 600
}
```

Build `Texml` by substituting `{PHONEZERO_XAI_SIP_NUMBER}` into `texml/bridge.xml` (strip XML comments and newlines). Do not send `Url` — the request schema is oneOf: `Url` XOR `Texml` XOR neither.

**Schema lag:** `get_api_endpoint_schema` for `calls_accounts_texml_calls` does **not** list `Texml` (the MCP's OpenAPI snapshot lags the API). `invoke_api_endpoint` still passes `Texml` through and it works. Do not "correct" yourself off the schema — omit `Url` and send `Texml`.

- `To` / `From`: E.164 only. `From` is exactly `PHONEZERO_FROM_NUMBER`.
- Recording is call-level (`Record` true, `RecordingChannels` `dual`). Do not put `record` on `<Dial>`.
- Restaurant AMD is call-level (`MachineDetection` `Enable`, `AsyncAmd` true). Do not put AMD on `<Sip>` — that would classify the xAI agent, not the restaurant.
- `Timeout` 30 is the ring timeout in seconds before no-answer. Do not raise it.
- `TimeLimit` 600s is the per-call duration cap. Do not raise it.
- `AsyncAmd` must be `true`. Synchronous AMD blocks TeXML waiting for a status callback PhoneZero does not run. Read the AMD result post-hoc from `answered_by` on the retrieve-call endpoint (`human` | `machine` | `not_sure`): treat `machine` as voicemail, `not_sure` as human.
- If the restaurant's reservations extension is known **and** the MCP tool schema includes `SendDigits`, add `"SendDigits": "ww2"` (or the known sequence; `w` = 500ms pause). Mid-call DTMF is not available in this architecture — if you do not know the extension, omit it.

On success, store `sid` / `CallSid` as `call_sid`. On MCP/HTTP error: outcome `failed`. Do not retry in the same turn; tell the user what Telnyx returned (no secrets).

## 7. Poll for completion

Poll the same MCP: `invoke_api_endpoint` with `endpoint_name` `retrieve_calls_accounts_texml_calls` and args `account_sid`, `call_sid` (REST equivalent: `GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}`). Returns `status`, `duration`, and `answered_by`. Under async AMD, `answered_by` values `human` | `machine` | `not_sure` appear post-hoc.

This endpoint is eventually consistent.

| Field | Action |
|---|---|
| `status` `ringing`, `in-progress` | Keep polling. |
| `status` `completed` | Go to recordings. |
| `status` `no-answer`, `busy` | Not a booking; apply §5 retry; report `no_answer` only when `attempts >= 2`. |
| `status` `failed`, `canceled` | Outcome `failed` always. Never `booked`. Do not override from a transcript. If a transcript exists, quote it under `failed` only. |
| `answered_by` `machine` | Still wait for `completed`, then treat as voicemail unless a **non-agent channel** (never merged text) contains a human turn; the recap alone never upgrades it. |
| `answered_by` `human` or `not_sure` | Treat as human. `not_sure` is human. |

Poll every 10s while live. **Call timeout:** 12 minutes from dial. If still `ringing` / `in-progress` at 12 minutes, stop polling the live call, try recordings once, and if nothing usable → `unknown` (never `booked`).

## 8. Recording + transcription

Telnyx does **not** transcribe Dial-verb recordings. TeXML transcription exists only for `<Record transcription="true">` and the webhook-dependent `<Transcription>` verb. There is no post-hoc "create transcription" API. xAI STT is the default outcome path. The xAI Builder console is review-only — not on the critical path.

After a terminal call status:

1. Fetch recordings via the Telnyx MCP: `invoke_api_endpoint` with `endpoint_name` `recordings_json_calls_accounts_texml_recordings_json` (REST equivalent: `GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}/Recordings.json`). Response: `recordings[].media_url` (S3 presigned, expires ~600s / ~10 min) and `recordings[].sid`. Poll every 15s for up to 3 minutes after call end until a completed recording with a `media_url` exists. If none: outcome `unknown`. Never `booked`.
2. Download the dual-channel `media_url` **promptly** to a temp file on this computer (the presigned URL expires in ~10 minutes; do not commit it; do not paste the URL in chat).
3. Confirm `XAI_API_KEY` is in the environment. If missing: **stop**. Start the secure secret request flow. Never ask for the key in chat. Never echo it. Do not classify `booked`.
4. Transcribe with xAI STT. `file` must be the last multipart field:

```bash
curl -sSg -X POST https://api.x.ai/v1/stt \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -F multichannel=true \
  -F format=true \
  -F language=en \
  -F file=@/tmp/phonezero-{call_sid}.audio
```

5. The multichannel response includes a `channels` array (one transcript per speaker). Identify the **agent** channel as the one whose `text` contains the canonical opener ("calling on a recorded line" / "I'd like to make a reservation"). The other channel is the **host**. If `channels` is missing or the opener cannot identify the agent channel: outcome `unknown`, never `booked`.

If STT fails or returns empty text: outcome `unknown`. Never `booked`. You may retry the call later under §5 (absence is not a booking).

## 9. Extract the outcome

The voice agent always ends with:

`Confirming: booked / not booked, {time}, party of {n}, under {name}.`

Read the **closing lines** of the agent channel for that sentence. Then independently check the host channel. If `channels` is missing or the agent channel was not identified in §8, outcome is already `unknown` — do not search merged text for a booking.

**`booked` only if all of these are true:**

1. The recap says `booked` (not `not booked`).
2. A **host** turn (the non-agent channel, identified in §8) confirms the reservation — e.g. they accept the time, say they have the party down, or answer yes to the agent's verbatim read-back.
3. The recap's `{time}` is inside the approved window or the pre-briefed alternates.
4. Recording exists and xAI STT returned a transcript.

The agent's recap alone is not enough. If the recap says `booked` but the host never confirmed, classify `unknown` and say so. Never invent a confirmation number or a time that is not in the transcript.

Map everything else:

| Situation | Outcome |
|---|---|
| Recap `not booked`, host said they are full / no times in window or alternates | `unavailable` |
| No human (ring/no-answer/busy) or voicemail only, after retries exhausted | `no_answer` |
| Voicemail on attempt 1 of 2 | not terminal — retry per §5; do not report a final outcome yet |
| Host offered a time **outside** window/alternates; recap `not booked` with that time | `needs_user` |
| Host objected to recording or to an AI caller | `needs_user` |
| Wrong number, not a restaurant, host asked a human to call back | `needs_user` |
| Missing recording/transcript, unparseable recap, recap/host disagree | `unknown` |
| Call abandoned mid-hold, recap `not booked`, host never refused | `unknown` |
| Call `status` `failed` or `canceled` | `failed` always. Never `booked`. Quote a transcript under `failed` only. |
| MCP/dial/API failure | `failed` |

Valid outcome states (exactly one): `booked` | `unavailable` | `no_answer` | `needs_user` | `unknown` | `failed`.

## 10. Delete artifacts

After successful STT (and the outcome is classified / you are ready to report it), delete both local audio and the Telnyx recording. Scripts delete the Telnyx recording by default after STT; do the same here.

1. Delete the local temp audio file.
2. Delete the Telnyx recording via the same MCP: `invoke_api_endpoint` with `endpoint_name` `delete_recording_sid_json_recordings_accounts_texml_json` (REST equivalent: `DELETE /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Recordings/{recording_sid}.json`; returns 204).

There is no Telnyx transcription to delete.

If the Telnyx delete fails, say that cleanup failed and leave the recording SID in conversation memory so you can retry delete. Still report the outcome. Deleting audio does not undo the fact of recording; the opener already disclosed a recorded line.

Do not copy raw audio or full transcripts into chat. Quote only the recap line and the host confirmation phrase you relied on.

## 11. Counter-offer tiers

There is no mid-call relay to you. Three tiers:

1. **In-window / pre-briefed alternates (default).** Already in the TASK BRIEF. The agent accepts on the spot. You report `booked` at that time (host confirmation still required).
2. **Out-of-window offer.** Agent must not accept. It asks the host to hold if possible, recaps `not booked` with the offered time. You report `needs_user`, show the offer in chat, and wait. If the user accepts, replace the TASK BRIEF for a **confirmation callback** (narrow ask: lock the held time) and run §4–§10 again. If they decline, stop (`unavailable`) or collect a new window.
3. **Live calendar tool mid-call** — not available. Do not pretend it is.

## 12. Report and calendar

Report in chat, one state, concrete facts:

- `booked` — restaurant, date, time, party, name, any host notes. Offer to create the calendar event yourself (title, start, duration ~90 minutes unless they say otherwise, location, phone, party). Only write the calendar if they want it.
- `unavailable` — what the host said; do not call again for the same slot unless they change the window.
- `no_answer` — attempts used; offer a later retry as a new plan.
- `needs_user` — the exact offer or objection; ask what to do.
- `unknown` — why (no transcript, recap/host mismatch). Do not claim a table.
- `failed` — what broke (Telnyx status / MCP / STT error). Do not claim a table.

## Hard rules

- No call without §1 call-time variables, a complete collect, an online-booking attempt, an hours check, and an explicit yes to the current plan.
- No `booked` without a Telnyx recording and an xAI STT transcript that contains both the recap and a host confirmation.
- No secrets, no keys in chat, no non-fixture numbers written into skills or examples.
- One restaurant, one task, max two attempts, 20 minutes apart.
- Never edit STATIC BEHAVIOR in Builder. Only replace TASK BRIEF.

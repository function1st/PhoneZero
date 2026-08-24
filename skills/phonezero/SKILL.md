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
| `PHONEZERO_TEXML_BIN_URL` | Public TeXML Bin URL (`Url` on the dial). The bin bridges the answered call to `sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai`. |
| `PHONEZERO_XAI_SIP_NUMBER` | Setup-time only. E.164 registered with xAI Direct SIP; already baked into the bin. Not passed on the dial. |
| `PHONEZERO_AGENT_NAME` | Spoken name in the TASK BRIEF (`{agent_name}`). |
| `PHONEZERO_DISCLOSE_AI` | Boolean, default `true`. When true, TASK BRIEF `{disclosure_clause}` is `, an automated assistant,`. When false, empty. The agent still answers truthfully if asked whether it is an AI. |
| `XAI_API_KEY` | Environment only. Entered once via Grok Bot's secure secret request flow (masked, excluded from transcripts and model context). Used solely for `POST https://api.x.ai/v1/stt`. Never ask for this key in chat. Never echo it. |

Call-time required: `TELNYX_API_KEY` (working MCP), `TELNYX_ACCOUNT_SID`, `PHONEZERO_FROM_NUMBER`, `PHONEZERO_TEXML_APP_ID`, `PHONEZERO_TEXML_BIN_URL`, `PHONEZERO_AGENT_NAME`, `XAI_API_KEY`. `PHONEZERO_DISCLOSE_AI` may be absent (treat as `true`). `PHONEZERO_XAI_SIP_NUMBER` is not required at dial if the bin is already configured.

If any call-time variable is missing, or the Telnyx MCP is disconnected / 401s: **stop. Do not dial.**

- Plugin / MCP gaps: tell the user PhoneZero is not configured and that they should say *"Set up phone calling."* You then walk setup on this computer and browser (Telnyx DID, TeXML app, TeXML bin, Voice Agent Builder + SIP). They enter `TELNYX_API_KEY` and `TELNYX_ACCOUNT_SID` only in the plugin config UI.
- Missing `XAI_API_KEY`: stop and start Grok Bot's **secure secret request** flow for `XAI_API_KEY`. Never ask them to paste it in chat. After it is in the environment, re-check.

Do not invent `{TELNYX_ACCOUNT_SID}`.

## 2. Collect before any call

Do not dial until every required field is known. Ask for missing pieces. Fail closed: if the task stays vague after one clarifying turn (no restaurant, no day, "sometime," "a place downtown"), **do not call**.

Required:

| Field | Rules |
|---|---|
| Restaurant name | As the host will recognize it. |
| Restaurant phone | E.164 (`+1…`). If you only have a name, look the number up, show it, and get confirmation. Reject non-US numbers. |
| Date | Concrete calendar date. |
| Preferred time | The first ask. |
| Window start–end | Inclusive acceptable range on that date. |
| Ranked alternates | Ordered fallback times the agent may accept without asking you. |
| Party size | Integer ≥ 1. |
| Booking name | Name on the reservation. |
| Callback phone | E.164 the agent leaves on voicemail and gives if the host asks. Default to the user's phone; confirm it. |

Optional: special requests (high-top, allergies, stroller). Pass through; do not invent.

**Window and alternates.** If the user said "around 7" and did not give a window, propose a default (preferred ± 30–60 minutes, e.g. 6:30–8:00) and the ranked in-window slots (e.g. 6:45, 7:15, 7:30). Confirm that proposal in the call plan — do not silently widen it.

**Calendar.** If this Bot can read the user's calendar, compute alternates as times inside the window that do not conflict (travel buffer ~30 minutes before/after existing events). Rank: preferred time first, then nearest free in-window slots. If a backup day is free and the user allowed it, list it as a lower-rank alternate and say so in the plan. If there is no calendar access, use only the user's stated flexibility.

Hold this task in conversation memory: restaurant, E.164, date, preferred time, window, ranked alternates, party, booking name, callback, special requests, `attempts` (0–2), prior `call_sid`s, last outcome.

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
- Window: {window_start}–{window_end}
- Alternates the agent may accept (in order): {alternates}
- Special requests: {special_requests or "none"}
- From: {PHONEZERO_FROM_NUMBER}
- Callback if they miss us: {callback_phone}
- Attempt: {attempt} of 2
```

Dial **only** on an explicit yes to this plan ("yes", "go ahead", "call them"). Not implied consent, not "sounds good I guess," not a new unrelated message. If they edit the plan, re-show it and wait again.

Never auto-dial. Never dial because a previous task was approved. Vague task → no call.

## 5. Calling-hours guard and attempt cap

Place a call only when **all** of these hold:

1. **US destination** (already required).
2. **Plausible open hours for that restaurant**, in the restaurant's local timezone if known, otherwise the user's timezone. Look up hours when you can. If unknown, allow 10:30–20:30 local on typical service days only. Never call 22:00–09:00 in the user's local timezone. Never call a time you know the restaurant is closed.
3. **`attempts` < 2** for this task. Maximum two call attempts. Attempts are 20 minutes apart (wall clock). A confirmation callback after an out-of-window hold is a **new** plan (still needs yes) and does not count against the original task's two attempts unless it is a retry of the same unanswered ask.
4. The user has explicitly approved the current plan.

If it is outside calling hours: say when you will call, and wait (or ask them to tell you to proceed at that time). Do not skip the hours guard because they are impatient unless they explicitly override **and** it is still within 09:00–21:00 their local time.

Voicemail / no-answer: leave the message (the agent does this), increment `attempts`, wait 20 minutes, re-check hours, re-show a one-line plan ("retry #2, same ask"), and dial only on yes. After two attempts still no human: outcome `no_answer`. Stop.

## 6. Brief the voice agent, then dial

`prompts/voice-agent.md` has two sections:

- **STATIC BEHAVIOR** — loaded once at setup. Never edit this section per call.
- **TASK BRIEF** — the only block you replace. In the Voice Agent Builder console, substitute this call's values into the TASK BRIEF delimited block and replace that block only. Do not dial with a stale brief from a prior restaurant or window.

`{agent_name}` is `PHONEZERO_AGENT_NAME`. `PHONEZERO_DISCLOSE_AI` defaults `true` → `{disclosure_clause}` = `, an automated assistant,`. If `false`, `{disclosure_clause}` is empty. The agent still answers truthfully if asked whether it is an AI. EU destinations are out of v1 scope.

### Dial — Telnyx hosted MCP

Use the Telnyx hosted MCP (auth is the plugin bearer; you never pass the key). Map to:

`POST /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls`

JSON body (field names are PascalCase as Telnyx TeXML requires):

```json
{
  "ApplicationSid": "{PHONEZERO_TEXML_APP_ID}",
  "To": "{restaurant_phone}",
  "From": "{PHONEZERO_FROM_NUMBER}",
  "Url": "{PHONEZERO_TEXML_BIN_URL}",
  "MachineDetection": "Enable",
  "DetectionMode": "Premium",
  "AsyncAmd": true,
  "Timeout": 30,
  "TimeLimit": 600
}
```

- `To` / `From`: E.164 only. `From` is exactly `PHONEZERO_FROM_NUMBER`.
- `Url` is exactly `PHONEZERO_TEXML_BIN_URL` (the bin performs the SIP bridge and dual-channel recording). Do not inline TeXML.
- `TimeLimit` 600s is the per-call duration cap. Do not raise it.
- `AsyncAmd` must be `true`. Synchronous AMD blocks TeXML waiting for a status callback PhoneZero does not run. Read the AMD result post-hoc from `answered_by` on the call-fetch endpoint (`human` | `machine` | `not_sure`): treat `machine` as voicemail, `not_sure` as human.
- If the restaurant's reservations extension is known **and** the MCP tool schema includes `SendDigits`, add `"SendDigits": "ww2"` (or the known sequence; `w` = 500ms pause). Mid-call DTMF is not available in this architecture — if you do not know the extension, omit it.
- Do not set `Record` on this request; recording is the bin's job.

On success, store `sid` / `CallSid` as `call_sid`. On MCP/HTTP error: outcome `failed`. Do not retry in the same turn; tell the user what Telnyx returned (no secrets).

## 7. Poll for completion

Poll the same MCP:

`GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}`

This endpoint is eventually consistent.

| Field | Action |
|---|---|
| `status` `ringing`, `in-progress` | Keep polling. |
| `status` `completed` | Go to recordings. |
| `status` `no-answer`, `busy` | Outcome `no_answer` (retry rules in §5). No `booked`. |
| `status` `failed`, `canceled` | Outcome `failed` unless you have a transcript that says otherwise. |
| `answered_by` `machine` | Still wait for `completed`, then treat as voicemail unless a human later appears in the transcript. |
| `answered_by` `human` or `not_sure` | Treat as human. `not_sure` is human. |

Poll every 10s while live. **Call timeout:** 12 minutes from dial. If still `ringing` / `in-progress` at 12 minutes, stop polling the live call, try recordings once, and if nothing usable → `unknown` (never `booked`).

## 8. Recording + transcription

Telnyx does **not** transcribe Dial-verb recordings. TeXML transcription exists only for `<Record transcription="true">` and the webhook-dependent `<Transcription>` verb. There is no post-hoc "create transcription" API. xAI STT is the default outcome path. The xAI Builder console is review-only — not on the critical path.

After a terminal call status:

1. Fetch recordings via the Telnyx MCP: `GET /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Calls/{call_sid}/Recordings.json`. Poll every 15s for up to 3 minutes after call end until a completed recording with a `media_url` exists. If none: outcome `unknown`. Never `booked`.
2. Download the dual-channel `media_url` to a temp file on this computer (do not commit it; do not paste the URL in chat).
3. Confirm `XAI_API_KEY` is in the environment. If missing: **stop**. Start the secure secret request flow. Never ask for the key in chat. Never echo it. Do not classify `booked`.
4. Transcribe with xAI STT. `file` must be the last multipart field:

```bash
curl -X POST https://api.x.ai/v1/stt \
  -H "Authorization: Bearer $XAI_API_KEY" \
  -F multichannel=true \
  -F file=@/tmp/phonezero-{call_sid}.audio
```

5. The multichannel response includes a `channels` array (one transcript per speaker). Identify the **agent** channel as the one whose `text` contains the canonical opener ("calling on a recorded line" / "I'd like to make a reservation"). The other channel is the **host**. If only a merged `text` is present and `channels` is missing, do not treat speaker identity as proven — you may still search the merged text for the recap, but you cannot mark `booked` without a host-side confirmation you can attribute.

If STT fails or returns empty text: outcome `unknown`. Never `booked`. You may retry the call later under §5 (absence is not a booking).

## 9. Extract the outcome

The voice agent always ends with:

`Confirming: booked / not booked, {time}, party of {n}, under {name}.`

Read the **closing lines** of the agent channel (or merged text if channels are unusable) for that sentence. Then independently check the host channel.

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
| MCP/dial/API failure, `status=failed` with no usable transcript | `failed` |

Valid outcome states (exactly one): `booked` | `unavailable` | `no_answer` | `needs_user` | `unknown` | `failed`.

## 10. Delete artifacts

After the outcome is classified (and you are ready to report it):

1. Delete the local temp audio file.
2. Delete the Telnyx recording via the same MCP: `DELETE /v2/texml/Accounts/{TELNYX_ACCOUNT_SID}/Recordings/{recording_sid}.json`.

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

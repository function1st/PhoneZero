---
name: book-restaurant
description: Book a restaurant table by phone when no online reservation exists. Invoke for restaurant reservations, calling a business to book a table, /book-table, /book-restaurant, or delegating a dining phone call (OpenTable/Resy unavailable, restaurant takes reservations by phone only). Do not invoke for SMS, email booking, bulk calling, or non-dining phone tasks.
---

# Book restaurant

Collect a reservation, try online booking first (unless they skip it), show a call plan, then hand off to [`phonezero-runtime`](../phonezero-runtime/SKILL.md) to dial. The voice agent loads a `phonezero-task` whose reservation wording lives in **this brief**, not in the Builder prompt.

Read `phonezero-runtime` for Setup, preconditions, plan-first, hours hard cap, dial/poll/STT, shared outcomes, and artifacts. Do not duplicate the Telnyx loop here.

## Optionality (chat overrides, not Configure fields)

| Knob | Default | Override in chat |
|---|---|---|
| Online first (OpenTable/Resy/restaurant site/Google Reserve) | on | “skip online / phone only” |
| Restaurant-local hours when hours unknown | 10:30–20:30 restaurant-local (user TZ if unknown) | user-stated hours |
| Window if they said “around 7” | propose preferred ± 30–60 min + ranked in-window slots | user-supplied window |
| Calendar offer after `succeeded` | offer ~90 minutes | skip |
| Spoken name | PhoneZero | per-call (`spoken_name` in the brief) |

## Collect

Do not dial until every required field is known. Fail closed after one clarifying turn if the task stays vague (no restaurant, no day, "sometime," "a place downtown").

| Field | Rules |
|---|---|
| Restaurant name | As the host will recognize it. |
| Restaurant phone | E.164. If you only have a name, look the number up, show it, and get confirmation. Reject numbers whose country is not in the Telnyx **PhoneZero US-only** `whitelisted_destinations`. `+1` covers Canada and Caribbean NANP too — confirm the actual country, ask if unsure, refuse on no. |
| Date | Concrete calendar date. |
| Preferred time | The first ask. |
| Window start–end | Inclusive acceptable range on that date. Concatenate into `{window}` (e.g. `6:30 PM to 8:00 PM`). |
| Ranked alternates | Ordered fallback times the agent may accept without asking you. |
| Party size | Integer ≥ 1. |
| Booking name | Name on the reservation. |
| Callback phone | E.164 the agent leaves on voicemail. Default to the user's phone; confirm it. |

Optional: special requests (high-top, allergies, stroller). Pass through; do not invent. Optional spoken name for this call.

**Window and alternates.** Collect start and end, then concatenate into `{window}`. If the user said "around 7" and did not give a window, propose the default (± 30–60 minutes) and ranked in-window slots. Confirm that proposal in the call plan — do not silently widen it.

**Calendar.** If this Bot can read the user's calendar, compute alternates as times inside the window that do not conflict (travel buffer ~30 minutes). Rank: preferred first, then nearest free in-window slots. If a backup day is free and they allowed it, list it as a lower-rank alternate and say so in the plan.

Hold in conversation memory: restaurant, E.164, date, preferred time, `{window}`, ranked alternates, party, booking name, callback, special requests, spoken name, `attempts`, prior `call_sid`s, last outcome.

## Online first

Before any call plan, unless they said phone-only: try to book in the Bot's own browser (OpenTable, Resy, the restaurant's site, Google Reserve). Same date, time, party, name.

- Online path succeeds: report the confirmation. Offer calendar. **Do not call.**
- Online path needs the user (login, payment, captcha): hand it off in chat. **Do not call** unless they explicitly want the phone path.
- Call only when there is no working online path, or they skipped online.

## Hours (in addition to runtime hard cap)

Runtime already blocks outside **09:00–21:00 user-local**. Also:

- Known restaurant hours: only while open, and still inside the hard cap.
- Unknown restaurant hours: **10:30–20:30 restaurant-local** (user timezone if restaurant TZ is unknown).
- Never call a time you know the restaurant is closed.
- Override to call outside restaurant hours but still inside 09:00–21:00 user-local = a **new plan** and a fresh yes.

Owner setup-test to their own confirmed number: follow runtime exception (skip restaurant-hours and the hard cap). Never for calling a restaurant.

## Call plan

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

Dial only on an explicit yes. Then build the brief and hand to runtime §5–§10.

## Task brief

`put_task` with `skill: book-restaurant` (or `put_booking` with the legacy object — the MCP wraps it).

```json
{
  "kind": "phonezero-task",
  "skill": "book-restaurant",
  "spoken_name": "{agent_name}",
  "disclose_ai": true,
  "callee": { "name": "{restaurant_name}", "phone": "{restaurant_phone}" },
  "callback": "{callback_phone}",
  "goal": "Book the table within the window.",
  "opener": "I'd like to make a reservation for a party of {n} on {date} at {preferred_time}. Do you have availability?",
  "constraints": [
    "Accept only the preferred time, ranked alternates, or a host offer inside the window.",
    "Never invent a time."
  ],
  "success": "Live host confirms read-back of party, date, agreed time, and booking name.",
  "voicemail": "This is {spoken_name} calling for {booking_name} about a reservation for {n} on {date} at {preferred_time}. Please call {callback}. Thank you.",
  "playbook": "Ask preferred first; then alternates in order; then in-window host offers. Mention special requests only after a time is under discussion.",
  "facts": {
    "party": 2,
    "date": "{date}",
    "preferred_time": "{time}",
    "window": "{window}",
    "alternates": ["{alt1}", "{alt2}"],
    "booking_name": "{booking_name}",
    "special_requests": "none"
  }
}
```

See [references/voice-playbook.md](references/voice-playbook.md) if you need a longer chat-side reminder. Keep the uploaded `playbook` short.

TeXML `<Dial>` uses `{restaurant_phone}` (same as `callee.phone`).

## Classify (on top of runtime §8)

Runtime states: `succeeded | unavailable | no_answer | needs_user | unknown | failed`.

In chat you may say **`booked`** when the outcome is `succeeded`. Personas may still use `booked`.

`succeeded` / `booked` extra gates (all required, in addition to runtime):

1. Agent read back party, date, time, and booking name; host turn confirmed.
2. Confirmed time is inside `{window}` or ranked `alternates`.
3. Uploaded facts had restaurant, party, date, preferred time, window, and booking name.

Identify the agent channel by “calling on a recorded line” and/or “I'd like to make a reservation”.

| Situation | Outcome |
|---|---|
| Host full / no times in window or alternates | `unavailable` |
| Host offered a time **outside** window/alternates | `needs_user` |
| Wrong number, not a restaurant | `needs_user` |

## Counter-offers

1. In-window / pre-briefed alternates — agent accepts; you report `booked` (`succeeded`) if host confirmed the read-back.
2. Out-of-window — agent must not accept. Report `needs_user`. If they accept the offer, new brief (narrow ask: lock the held time) and runtime again.
3. Live calendar mid-call — not available.

## Report

- `booked` / `succeeded` — restaurant, date, time, party, name, host notes. Offer a calendar event (title, start, duration ~90 minutes unless they say otherwise, location, phone, party). Only write the calendar if they want it, or skip if they declined the knob.
- Other states: runtime report wording. Do not claim a table.

## Hard rules

- No call without runtime §1, a complete collect, an online attempt (unless skipped), restaurant + runtime hours checks, and an explicit yes.
- No `booked` unless runtime §8 and this skill’s extra gates hold.
- One restaurant, one task, max two attempts, 20 minutes apart.
- Never edit the Builder prompt. Reservation language belongs in this brief.

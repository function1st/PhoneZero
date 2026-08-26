---
name: confirm-business-hours
description: Call a business to confirm opening hours. Invoke for /confirm-business-hours, “are they open Saturday”, “confirm hours by phone”, or checking whether today’s hours differ. Do not invoke for restaurant reservations (use book-restaurant) or SMS.
---

# Confirm business hours

Collect who to call and what we need confirmed. No OpenTable step. Hand off to [`phonezero-runtime`](../phonezero-runtime/SKILL.md) to dial. Hours guard is the runtime **09:00–21:00 user-local** cap only (plus owner setup-test exception).

## Collect

| Field | Rules |
|---|---|
| Business name | As they will recognize it. |
| Business phone | E.164. Look up if needed, show it, get confirmation. Country must be on the Telnyx profile attached to the PhoneZero TeXML app. |
| Callback | E.164. Default to the user's phone; confirm it. |
| Expected hours (optional) | What we think the hours are, or a specific question (“open Saturday?”, “today’s holiday hours?”). |

Spoken name defaults to PhoneZero; override per call. Fail closed if there is no business or no number after one clarifying turn.

## Call plan

```
Call plan
- Who: {business_name}
- Number: {business_phone}
- Ask: confirm opening hours{optional expected / Saturday / today}
- Spoken as: {agent_name}
- From: {PHONEZERO_FROM_NUMBER}
- Callback if they miss us: {callback_phone}
- Attempt: {attempts + 1} of 2
```

Dial only on an explicit yes. Then `put_task` and runtime §5–§10.

## Task brief

```json
{
  "kind": "phonezero-task",
  "skill": "confirm-business-hours",
  "spoken_name": "{agent_name}",
  "disclose_ai": true,
  "callee": { "name": "{business_name}", "phone": "{business_phone}" },
  "callback": "{callback_phone}",
  "goal": "Get a live person to state the opening hours (and whether they differ today, if asked).",
  "opener": "I'm calling to confirm your opening hours{optional: especially {focus}}.",
  "constraints": [
    "Do not invent hours.",
    "Accept only hours a live person states on this call."
  ],
  "success": "Live person states the opening hours (and answers the optional focus). Read back the hours they stated and get a yes.",
  "voicemail": "This is {spoken_name} calling to confirm {business_name} hours. Please call {callback}. Thank you.",
  "playbook": "Ask for hours. If a focus was briefed, ask that next. Read back the hours they stated. Do not guess.",
  "facts": {
    "expected_hours": "{optional or none}",
    "focus": "{optional e.g. Saturday or today}"
  }
}
```

Do not put reservation language in `opener` or `voicemail`. If the voice agent still says “reservation”, the Builder has the old prompt — stop and re-paste `prompts/voice-agent.md`.

## Classify

Runtime §8. Identify the agent channel by “calling on a recorded line” and the hours opener (not “I'd like to make a reservation”).

`succeeded` only if a live person on the non-agent channel stated hours and confirmed the read-back. Report the hours string exactly. Do not invent.

| Situation | Outcome |
|---|---|
| They refuse to give hours / cannot help | `unavailable` |
| Voicemail only after two attempts | `no_answer` |
| Wrong number | `needs_user` |

## Report

- `succeeded` — business name, the hours they stated, any “today differs” note. No calendar unless they ask.
- Other states: runtime wording. Do not claim hours you did not hear.

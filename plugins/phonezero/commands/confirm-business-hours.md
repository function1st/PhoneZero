---
name: confirm-business-hours
description: Call a business to confirm opening hours (PhoneZero phone skill)
---

# /confirm-business-hours

Read `skills/confirm-business-hours/SKILL.md` and `skills/phonezero-runtime/SKILL.md`. Collect business name, E.164, optional expected hours / focus, callback. Show the plan. On yes: `put_task` then runtime dial.

Do not use restaurant collect fields or `booked` gates. If the voice agent says “reservation”, the Builder still has the old prompt — re-paste `prompts/voice-agent.md`.

---
name: book-table
description: Book a restaurant table by phone with PhoneZero (plan-first, Telnyx MCP dial)
---

# /book-table

Read `skills/phonezero/SKILL.md` in full and follow it.

Collect the reservation, try online booking first, show the call plan, and dial **only** on an explicit yes. Telnyx MCP for numbers / apps / dial / poll / recordings. PhoneZero xAI MCP for `get_call_config`, `put_booking`, `transcribe`, `delete_booking`. Do not expect `$XAI_API_KEY` in the agent shell. Booking facts go in `phonezero-booking.json` on the xAI collection — no TeXML `<Say>`, no Builder edit per call. Keep the Telnyx recording. Delete the booking JSON after classify.

Never `source ~/.phonezero/env`. Never place a call without the skill's safety rules.

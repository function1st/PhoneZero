---
name: book-restaurant
description: Book a restaurant table by phone with PhoneZero (plan-first, Telnyx MCP dial)
---

# /book-restaurant

Read `skills/book-restaurant/SKILL.md` and `skills/phonezero-runtime/SKILL.md`. Follow collect → online first (unless skipped) → plan → runtime dial.

Telnyx MCP for numbers / apps / dial / poll / recordings. PhoneZero xAI MCP for `get_call_config`, `put_task` (or `put_booking` alias), `transcribe`, `delete_booking`. Facts go in `phonezero-task.json` — no TeXML `<Say>`, no Builder edit per call. Keep the Telnyx recording. Delete the live brief after classify. Do not delete templates.

Never `source ~/.phonezero/env`. Never place a call without the runtime safety rules.

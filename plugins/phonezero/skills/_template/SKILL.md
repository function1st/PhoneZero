---
name: my-phone-skill
description: Replace this. Say what the skill does and when to use it (the router). Copy this folder to ~/.phonezero/skills/<name>/ or ~/.cursor/skills/<name>/. Do not put keys or real phone numbers here.
---

# My phone skill

Copy this folder. Rename the directory and the `name` frontmatter to match (lowercase hyphenated). Fill collect + brief fields. Then a new Cursor chat can run it without a PR.

Grok Bot does **not** use this folder. On Grok, interview into a `phonezero-task` (see `phonezero-runtime` Ad-hoc).

## Collect

Required fields (edit these):

| Field | Rules |
|---|---|
| Callee name | As they will recognize it. |
| Callee phone | E.164. Confirm. Country must be on the Telnyx profile attached to the PhoneZero TeXML app. |
| Callback | E.164. Default to the user's phone; confirm it. |

Add only what the voice agent needs. Fail closed after one clarifying turn if the task stays vague.

## Call plan

Show who, number, goal, opener, constraints, success, spoken as, From, callback, attempt. Dial only on an explicit yes.

## Task brief

Hand off to [`../phonezero-runtime/SKILL.md`](../phonezero-runtime/SKILL.md) §5. `put_task` with `skill` = this folder name. Keep `playbook` short. Copy wording from [references/voice-playbook.md](references/voice-playbook.md).

## Classify

Use runtime §8. Set `success` so a live-person confirmation is unambiguous. Do not use restaurant `booked` gates unless this skill is actually a reservation.

## Hard rules

No keys. No real numbers in this file (fixtures `+15555550100` only). No Builder edit. No legal advice.

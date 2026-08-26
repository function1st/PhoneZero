# PhoneZero skills

PhoneZero is a **runtime** plus **phone skills**. The voice agent is one static Builder interpreter. Each call is a `phonezero-task.json` brief.

Contributing a skill to this repo is **optional**. Grok users are not asked to open a PR.

## Cursor — local folder (no PR)

Same layout as first-party skills:

```text
my-skill/
  SKILL.md
  brief.schema.json
  references/voice-playbook.md
```

Discovery (none of these require a contribution):

| Where | Who |
|---|---|
| `plugins/phonezero/skills/` | Shipped |
| `~/.cursor/skills/<name>/` or `~/.agents/skills/<name>/` | Cursor user |
| `~/.phonezero/skills/<name>/` | Cursor user (MCP `list_phone_skills` / `get_phone_skill`) |
| Project `.cursor/skills/` or `.phonezero/skills/` | Private repo |

Copy [`plugins/phonezero/skills/_template/`](../plugins/phonezero/skills/_template/) or run `/new-phone-skill`. Folder name must match `name` in the frontmatter. New conversation after you add it. Dial still goes through [`phonezero-runtime`](../plugins/phonezero/skills/phonezero-runtime/SKILL.md).

Do not put API keys or real phone numbers in a skill (fixtures `+15555550100` only).

## Grok Bot — interview into JSON

Do **not** paste a `SKILL.md`, clone a gist, or write `~/.cursor/skills`.

If the ask matches a shipped skill (`book-restaurant`, `confirm-business-hours`), follow that skill. Otherwise the runtime **Ad-hoc interview** builds a `phonezero-task` in chat (callee, callback, goal, opener, constraints, success, voicemail, facts). Show it in the call plan. Dial only on yes.

**Save as a template** only if they ask. Save the shape, not this call’s number/date unless they freeze those. The Bot picks a store and says where it went:

1. This chat, if they did not ask to save
2. Grok memory, if the host has it
3. `put_template` → `phonezero-template-{slug}.json` in **PhoneZero bookings** (never overwrite the live brief; never `delete_booking` a template)
4. Show the JSON in chat if 2 and 3 are unavailable

## Shipped skills

- [`phonezero-runtime`](../plugins/phonezero/skills/phonezero-runtime/SKILL.md) — setup, dial, STT, outcomes, Grok interview
- [`book-restaurant`](../plugins/phonezero/skills/book-restaurant/SKILL.md) — first skill; `/book-table` is an alias
- [`confirm-business-hours`](../plugins/phonezero/skills/confirm-business-hours/SKILL.md) — example second skill

## Builder

Paste [`plugins/phonezero/prompts/voice-agent.md`](../plugins/phonezero/prompts/voice-agent.md) as the system prompt. Paste [`plugins/phonezero/prompts/end_call.md`](../plugins/phonezero/prompts/end_call.md) as the `end_call` tool description.

Existing reservation-only agents must be re-pasted before hours or ad-hoc briefs will speak correctly. Say so if the test DID is also used in production.

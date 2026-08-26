---
name: new-phone-skill
description: Create a private Cursor phone skill from the PhoneZero template (no PR required)
---

# /new-phone-skill

Cursor only. Grok Bot interviews into a `phonezero-task` instead — do not tell Grok users to write a folder.

1. Read `skills/_template/SKILL.md` and `docs/SKILLS.md`.
2. Copy `plugins/phonezero/skills/_template/` to `~/.phonezero/skills/{name}/` (or `~/.cursor/skills/{name}/`). The folder name must match the `name` frontmatter (lowercase hyphens).
3. Fill collect fields, `brief.schema.json` facts, and `references/voice-playbook.md`.
4. No keys. No real phone numbers (fixtures `+15555550100` only).
5. Start a **new** conversation. The user can run the skill by asking for that task or invoking `/{name}`.
6. Dial still goes through `phonezero-runtime` (`put_task` → TeXML → STT). Do not edit the Builder prompt.

If they asked to save a just-finished ad-hoc call as a local skill, write that folder from the brief shape (not this call’s callee/date unless they freeze those).

---
name: phonezero-telnyx-canary
description: Grok Bot PhoneZero setup when pointed at https://github.com/function1st/PhoneZero. Invoke for set this up, set up phone calling, wire Telnyx, or list_api_endpoints on Grok Bot. Do not use the Cursor PhoneZero plugin on this host.
---

# Grok Bot — set this up

Computer-use. Drive the UI. Do these steps **in order**. Same playbook: repo-root [README.md](../../../../README.md) and [AGENTS.md](../../../../AGENTS.md). After ids are in session: [plugins/phonezero/skills/phonezero-runtime/SKILL.md](../../../phonezero/skills/phonezero-runtime/SKILL.md) and the matching phone skill (or interview a custom `phonezero-task` — do not ask for a `SKILL.md` paste).

1. **Not** Cursor + Add. **Not** Authenticate. **Not** keys in chat. **Not** `source ~/.phonezero/env`. **Not** `scripts/provision.sh`.
2. Vendor gate, then **ask in chat and wait** — spoken name and AI disclaimer ON/OFF only. Do **not** ask for destination countries.
3. HTTP MCP: `https://api.telnyx.com/v2/mcp` + `Authorization: Bearer` in the form. Edit Values include name / disclose.
4. `list_api_endpoints` — real list or stop. “6 tools” proves nothing. There is **no** MCP tool named `whoami`.
5. If `put_task` / `put_booking` is missing: add stdio `xai` from [`plugins/phonezero/mcp.json`](../../../phonezero/mcp.json) with **real** env (not `${…}`), including name / disclose. Then `get_call_config` + `ensure_collection`. If they said xAI is already set up, do not open the Builder. Ignore the wizard number. If they turned disclaimer OFF and Builder already exists, or the agent still searches `phonezero-booking.json`, re-paste `prompts/voice-agent.md` once.
6. Session ids **now**, before any plan:
   - `TELNYX_ACCOUNT_SID` = `invoke_api_endpoint` `list_billing_groups` args `{ "jq_filter": "[.data[].organization_id] | unique" }`
   - `PHONEZERO_TEXML_APP_ID` = `invoke_api_endpoint` `list_texml_applications` args `{ "filter": { "friendly_name": "PhoneZero" }, "jq_filter": ".data[] | {id, friendly_name}" }`
   - From = `get_call_config`
   - Destinations = `list_outbound_voice_profiles` → **PhoneZero US-only** → `whitelisted_destinations`. Show them. This is Telnyx Mission Control → Voice → Outbound voice profiles, not a PhoneZero field. PATCH only if they ask to change countries.
7. Provision only if profile / TeXML app / DID attach is missing. Do not overwrite an existing whitelist unless they asked.
8. On yes: `put_task` (or `put_booking` alias) → `calls_accounts_texml_calls` (session ids, do not look up SID again) → poll → recordings → `transcribe` → classify → `delete_booking` (live brief only).

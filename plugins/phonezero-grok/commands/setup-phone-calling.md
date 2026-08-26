---
name: setup-phone-calling
description: Grok Bot — ask name / AI disclaimer, then wire Telnyx HTTP + xAI stdio. Destinations are Telnyx. Not the Cursor plugin.
---

# /setup-phone-calling (Grok)

You are a computer-use agent. Run **Grok Bot — set this up** in repo-root `AGENTS.md` (same steps in `README.md`) **in order**. Do not install Cursor PhoneZero. Do not click Authenticate. Do not take keys in chat.

After the vendor gate, **ask in chat and wait** before wiring. Do not silently keep defaults:

- Spoken name (default PhoneZero) — what the callee hears
- AI disclaimer ON or OFF — they may turn it OFF

**Do not ask for destination countries.** Read them from Telnyx after the HTTP MCP is proven: the outbound voice profile **attached to the PhoneZero TeXML app** (any name) → `whitelisted_destinations`. `list_outbound_voice_profiles` with **no name filter**; pick the id on that TeXML app. Show the actual name + codes. That setting is Telnyx Mission Control → Voice → Outbound voice profiles. PATCH only if they ask to add or remove countries. Do not give legal advice.

Do not search Telnyx MCP for `whoami`. After Telnyx HTTP + xAI stdio are proven, resolve session ids immediately:

- `invoke_api_endpoint` `list_billing_groups` → `organization_id` = `TELNYX_ACCOUNT_SID`
- `invoke_api_endpoint` `list_texml_applications` filter `PhoneZero` → `PHONEZERO_TEXML_APP_ID`
- `get_call_config` → From last-4

Then provision only if those resources are missing. If they said xAI is already set up, skip the Builder unless they turned the disclaimer OFF (then re-paste the prompt once with `{disclosure_clause}` empty).

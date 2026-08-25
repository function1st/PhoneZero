---
name: setup-phone-calling
description: Vendor checklist, then PhoneZero Setup (Telnyx MCP provision + one Voice Agent Builder walkthrough)
---

# /setup-phone-calling

Read `skills/phonezero/SKILL.md` in full and follow **Setup**.

**First message, before any API call**, show this checklist:

```
Before we continue, you need:
- Telnyx account + KYC done
- One US number bought (that is From)
- Telnyx API key
- xAI team with Zero Data Retention (ZDR) OFF
- xAI API key from that same team
- Access to Voice Agent Builder at console.x.ai

Missing any of these? Stop and get them. Links: telnyx.com · console.x.ai · docs.x.ai/developers/faq/security
Then we fill the rest.
```

If any of those are missing, **stop**. Do not call Telnyx or xAI.

If they are in place: verify Telnyx MCP and the PhoneZero xAI MCP (`get_call_config`) with real `tools/call`s, then run the skill Setup (profile + TeXML app / attach DID / `register_byo_number` / `ensure_collection` → Builder once: paste `prompts/voice-agent.md`, welcome line, attach collection, `end_call` on with the skill's tool description, `attach_agent` onto the Telnyx DID — ignore the wizard number). A Files `403` mentioning Zero Data Retention means stop. Configure keys do not reach the agent shell — use the xAI MCP. **Do not** ask the user to paste ids back into Plugins → Configure.

Never `source ~/.phonezero/env`. Never echo keys. Scripts are developer-only.

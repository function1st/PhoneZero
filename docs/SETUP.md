# PhoneZero setup

This is the human-readable version of what `/setup-phone-calling` automates. Approve each credentialed step. UIs move; the invariants are a US DID, that same DID registered with xAI as `byo_trunk`, a TeXML application whose `voice_url` is the inbound reject page (outbound calls carry **inline Texml**, not a hosted bin), an xAI team with **ZDR off**, a **PhoneZero bookings** collection, a Builder voice agent (static prompt + welcome line + collection attached + `end_call` on) on that Telnyx DID, spend caps on both vendors, and three values on the Configure card (`TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `XAI_API_KEY`). Runtime: `POST https://api.x.ai/v1/stt` and Files. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Telnyx cannot transcribe Dial-verb recordings; the outcome path is recording `media_url` via Telnyx MCP → xAI `POST /v1/stt` (multichannel). Keep the Telnyx recording; delete the live `phonezero-task.json` after classify (do not delete templates).

Fixture numbers in this guide are reserved (`+15555550100`-style). Never commit a real number. You do **not** buy a second number: `PHONEZERO_FROM_NUMBER` is registered with xAI and is the SIP bridge target.

Account SID, TeXML app id, and collection id are created during provision — they are **not** on the Configure card. Enter the three card fields (A), then run `/setup-phone-calling` (B).

## Manual: Telnyx account, KYC, DID

1. Create a [Telnyx](https://telnyx.com/) account. Use a **dedicated** account for PhoneZero if you can — plugins are account-wide, so isolation lives at the vendor.
2. Complete Telnyx KYC / identity verification. This is the slowest step; start it first. Outbound voice stays blocked until it clears.
3. Buy one **US** DID (Mission Control → Numbers). This becomes `PHONEZERO_FROM_NUMBER` (caller ID and SIP bridge target after xAI registration). Example fixture only: `+15555550100`.

## Manual: xAI team (ZDR must be off)

PhoneZero briefs every call with `phonezero-task.json` in an xAI **collection**. [Zero Data Retention](https://docs.x.ai/developers/faq/security) is team-wide and **blocks Files and Collections** (`File uploads are not available under Zero Data Retention`). There is no sub-team and no per-key override.

4. Create an [xAI](https://console.x.ai) account.
5. Use a team with **ZDR off** (the default 30-day retention). Check the team picker — a **ZDR** badge means it is on. [Team Settings](https://console.x.ai/team/default/settings/team) → Zero Data Retention → **Disable**, or **+ Create Team** and leave ZDR off. Create the API key and the Voice Agent on **that** team. A key from a ZDR team cannot upload the task file.
6. Create an **API key** on that team. This is `XAI_API_KEY` (Files, collections, STT, phone-numbers API).
7. Confirm you can open **Voice Agent Builder** at [console.x.ai](https://console.x.ai). Agent create has no public API — this console step is required once.

## A — Keys first

The Telnyx MCP cannot run until `TELNYX_API_KEY` is saved as a plugin variable.

8. Install the PhoneZero plugin. This repository follows the official [plugin-template](https://github.com/cursor/plugin-template): [`.cursor-plugin/marketplace.json`](../.cursor-plugin/marketplace.json) at the repo root (required by Customize → **+ Add**), plugin at [`plugins/phonezero/`](../plugins/phonezero/). Supported channels ([docs](https://cursor.com/docs/plugins)):
   - **Customize → Plugins → + Add** → this **repo root**. Cursor requires `.cursor-plugin/marketplace.json` (or `.claude-plugin/marketplace.json`).
   - **Cursor Marketplace**, once PhoneZero is listed (this is also the Grok Bot / cloud-agent channel). Submit at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish).
   - **Local development** ([Test plugins locally](https://cursor.com/docs/plugins#test-plugins-locally)): copy `plugins/phonezero/` to `~/.cursor/plugins/local/phonezero` (`rsync -a plugins/phonezero/ ~/.cursor/plugins/local/phonezero/`), then Reload Window. Confirm the loaded version in `~/.cursor/plugins/local/phonezero/.cursor-plugin/plugin.json`.
   - **Team marketplace** (Teams/Enterprise): Dashboard → Plugins → Add Marketplace → *Import from Repo*. With the Cursor GitHub App installed you can enable **Auto Refresh** so pushes to `main` update the marketplace automatically.

   After any update: re-enter **every** required field on the Configure card (a field left blank is cleared on save — see step 9) and start a **new** conversation (existing chats do not pick up a newly installed or updated plugin).

   **Grok Bot** (point at `https://github.com/function1st/PhoneZero` and say *set this up*): the Bot follows [AGENTS.md](../AGENTS.md) **Grok Bot — set this up**. It must ask spoken name and AI disclaimer ON/OFF. Destination countries are the Telnyx voice-profile whitelist (not a PhoneZero field). Do not Customize → + Add this repo as the Cursor plugin. Add Telnyx as HTTP MCP `https://api.telnyx.com/v2/mcp` with `Authorization: Bearer` in the MCP form. Add/use the PhoneZero xAI stdio MCP. Resolve SID via `list_billing_groups` (not `whoami`). Do not click Authenticate.

   If none of those are available on Cursor IDE: `"telnyx": {"command":"npx","args":["-y","@telnyx/mcp"],"env":{"TELNYX_API_KEY":"${env:TELNYX_API_KEY}"}}`. A masked secret card alone does **not** authenticate an MCP.

   Open the Cursor dashboard → **Plugins → Configure** for PhoneZero.
9. Enter **only** these three required fields. Spoken name and disclose are per-task (chat), not this card. Destination countries are **not** on this card — they live on the Telnyx outbound voice profile. **When you re-save this config card, re-enter EVERY required field, not just the changed one.** Saving replaces all of PhoneZero's setup values; a field left blank is cleared.
   - `TELNYX_API_KEY` — **as a plugin variable**, not in chat. The plugin injects it as env into the Telnyx stdio MCP. You need a Telnyx DID first.
   - `PHONEZERO_FROM_NUMBER` — that DID, E.164.
   - `XAI_API_KEY` — from the ZDR-off team (step 5). Goes to the PhoneZero xAI MCP, not the agent shell. Do not paste API keys in chat.
10. Do **not** put account SID, TeXML app id, or collection id on this card. `/setup-phone-calling` resolves them.
11. Once `TELNYX_API_KEY` is saved, start a **new** conversation and **verify auth with a real tool call** (`list_api_endpoints` through the Telnyx MCP). An existing chat does not pick up a newly installed or updated plugin. Telnyx MCP discovery is public, so "connected, 6 tools" appears even with no key — only a successful `tools/call` proves the header is wired; a `401` / 10009 means it is not. A `403` on `POST https://api.x.ai/v1/files` that mentions Zero Data Retention means the key's team still has ZDR on — stop and fix step 5.

The Configure card must match [`plugins/phonezero/.cursor-plugin/plugin.json`](../plugins/phonezero/.cursor-plugin/plugin.json). Cursor injects those values into the plugin MCP processes only — **not** the agent shell. After save, start a **new** conversation and check Telnyx MCP plus the PhoneZero xAI MCP (`get_call_config`). Never `source ~/.phonezero/env` in chat. Never ask the agent to `curl` with `$XAI_API_KEY`.

**Defaults.** Destinations are the Telnyx profile **PhoneZero US-only** (`whitelisted_destinations`, default `US` on create) — Mission Control → Voice → Outbound voice profiles. PhoneZero has no plugin field for this. AI disclosure defaults on. Calls are recorded. You are solely responsible for lawful use; see [DISCLAIMER.md](../DISCLAIMER.md).

To add a country (e.g. Japan): change that Telnyx whitelist in Mission Control, or ask the Bot to PATCH `whitelisted_destinations`. Telnyx rejects calls outside that list.

| Name | Kind | When | Purpose |
|---|---|---|---|
| `TELNYX_API_KEY` | plugin variable (secret) | A | Env for Telnyx stdio MCP (`npx @telnyx/mcp`). Never in chat. |
| `PHONEZERO_FROM_NUMBER` | plugin variable | A | Telnyx US DID (E.164): outbound caller ID and SIP bridge target (`sip:{PHONEZERO_FROM_NUMBER}@sip.voice.x.ai;transport=tls`). |
| `XAI_API_KEY` | plugin variable (secret) | A | From a team with **ZDR off**. Injected into the PhoneZero xAI MCP only (Files, collections, STT, phone-numbers). Not in the agent shell. |
| Spoken name / disclose | per-task (`phonezero-task.json`) | chat | `spoken_name` and `disclose_ai`. Default PhoneZero / true. Not on the Configure card. `{disclosure_clause}` is pasted once into the Builder prompt. |
| Destinations | Telnyx voice profile **PhoneZero US-only** | Telnyx | `whitelisted_destinations`. Mission Control → Voice → Outbound voice profiles. Not a PhoneZero plugin variable. |
| `TELNYX_ACCOUNT_SID` | resolved in session | B | TeXML REST account SID. MCP: `list_billing_groups` → `data[].organization_id` (no `whoami` tool). Developer curl: `GET /v2/whoami` → `data.organization_id`. Not on the Configure card. |
| `PHONEZERO_TEXML_APP_ID` | resolved in session | B | TeXML application SID. Not on the Configure card. |
| `PHONEZERO_XAI_COLLECTION_ID` | resolved in session | B | Collection for `phonezero-task.json` and optional `phonezero-template-*.json`. Find-or-create name `PhoneZero bookings`. |

## B — Provision

Account, KYC, and the DID stay manual. Everything after that is API-automatable.

12. **End-user path.** Run `/setup-phone-calling` (or ask *"Set up phone calling."*). The first message is a vendor checklist — stop if anything is missing (including ZDR off). Then the Bot uses the Telnyx hosted MCP (`list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`) and `XAI_API_KEY` for xAI Files + phone-numbers. Approve each credentialed step. It will:
   - Resolve `TELNYX_ACCOUNT_SID` from Telnyx MCP `list_billing_groups` → `data[].organization_id` (developer curl: `GET /v2/whoami`).
   - Find-or-create outbound voice profile **PhoneZero US-only**: `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck` (the only accepted combo today; error 10015 otherwise), `whitelisted_destinations` default `["US"]` on create, `daily_spend_limit="5.00"`, `daily_spend_limit_enabled=true`. If the profile exists, keep its current whitelist. PATCH only if the user asks to add or remove countries.
   - Find-or-create TeXML application **PhoneZero** with `voice_url` = [`texml/inbound.xml`](../texml/inbound.xml) (default raw URL: `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`) and `voice_method=get`. **Verify that URL returns HTTP 200 before writing it.** That URL is fetched **only for inbound** calls to the DID. Outbound calls carry inline `Texml` (template [`plugins/phonezero/texml/bridge.xml`](../plugins/phonezero/texml/bridge.xml)).
   - Attach the DID: `PATCH /v2/phone_numbers/{phone_number_id}` `{"connection_id":"<texml_app_id>"}`.
   - Register the DID with xAI if it is not already registered: `POST https://api.x.ai/v2/phone-numbers` `{"name":"PhoneZero","phoneNumber":"+1…","origin":"byo_trunk"}`.
   - Find-or-create the file collection named **PhoneZero bookings** (`GET`/`POST https://api.x.ai/v1/collections`). A 403 mentioning Zero Data Retention means stop — the API key's team still has ZDR on.

13. **Developer path.** On a **personal machine that is allowed to hold keys**, never on the Bot computer, run [`scripts/provision.sh`](../scripts/provision.sh). Same Telnyx + BYO work, idempotent (check-before-create). `--dry-run` prints the plan without POST/PATCH. Collection find-or-create is [`scripts/put-booking-file.sh`](../scripts/put-booking-file.sh) (needs `XAI_API_KEY` on a ZDR-off team). Optional env:
    - `PHONEZERO_INBOUND_XML_URL` — override the default raw inbound.xml URL.
    - `XAI_API_KEY` — register the DID with xAI. The SIP bridge target is `PHONEZERO_FROM_NUMBER`.
    - `PHONEZERO_XAI_AGENT_ID` — attach a Builder agent (step 15) via the fieldMask PATCH.
    - `PHONEZERO_ALLOWED_COUNTRIES` — developer-only env. If set, writes that ISO list onto the Telnyx profile `whitelisted_destinations`. If unset, create uses `["US"]` and an existing profile is left as-is. Not a plugin variable.

14. **Create the Voice Agent (once, in Builder).** There is no public create API (`/v1/agents` is not enabled). Preferred: the Bot opens [https://console.x.ai](https://console.x.ai) with your approved session. Fallback: you do this and give the Bot the `agentId`. On the **same ZDR-off team** as the API key:

    1. Voice Agent Builder → create one agent. Name is yours (spoken name at call time comes from `phonezero-task.json`, not this label).
    2. Paste the body of [`plugins/phonezero/prompts/voice-agent.md`](../plugins/phonezero/prompts/voice-agent.md) (system prompt only). Substitute `{disclosure_clause}` once: `, an automated assistant,` if they want disclose on (default), else empty. Do **not** substitute a spoken name. Save. Do not add a per-call TASK BRIEF — facts are the collection file. Never edit the Builder prompt per call. **Re-paste** this interpreter if the agent still searches `phonezero-booking.json` or still says it is only booking tables. If this DID is also used in production, say so before pasting.
    3. **Welcome message: on.** Text exactly `PhoneZero is ready!` **Caller can interrupt: on.** Empty welcome delays `collections_search` until the callee says hello. This line is spoken on the agent's SIP ear during the TeXML pause; the callee is not bridged yet and must not hear it. It is the session-start cue (search `phonezero-task.json` now), not a greeting. Do not put task facts in it.
    4. **Knowledge / file search:** attach collection **PhoneZero bookings**. Without this, the agent invents the ask.
    5. **`end_call` tool: on.** Name exactly `end_call`. Description = the full contents of [`plugins/phonezero/prompts/end_call.md`](../plugins/phonezero/prompts/end_call.md) (no extra words). The system prompt already calls this after a spoken goodbye. A silent hang-up with no goodbye has dropped live calls — do not leave the tool off.
    6. **Max call duration:** at least 10 minutes if the console exposes it (Telnyx already caps the bridge at 600s).
    7. **Guardrails** if shown: stay inside `constraints`, verbatim read-back of `success`, no invented confirmation.
    8. The wizard attaches the agent to a **new free xAI number**. **Ignore that number.** PhoneZero always SIP-bridges to your Telnyx DID.

    `{disclosure_clause}` is baked into the prompt at this paste (`, an automated assistant,` if they want disclose on, else empty). Changing your mind later means re-paste — there is no Configure toggle.

15. **Attach the agent to the registered Telnyx DID** (never the wizard's free number). `GET https://api.x.ai/v2/phone-numbers` → find YOUR DID's `phoneNumberId` (`origin` `byo_trunk`; E.164 matches `PHONEZERO_FROM_NUMBER`) → `PATCH https://api.x.ai/v2/phone-numbers/{phoneNumberId}` body `{"phoneNumber":{"agentId":"agent_…"},"fieldMask":{"paths":["agent_id"]}}` — protobuf FieldMask style; a flat `{"agentId":…}` is rejected. Copy `agentId` from the wizard number row in the same GET, then PATCH it onto the DID. `provision.sh` does this when `PHONEZERO_XAI_AGENT_ID` is set. Or attach in Builder **to the Telnyx DID**.
16. Set a **Telnyx spend cap** on the outbound voice profile (enable daily spend limit; `provision.sh` sets `$5.00`). Caps reset 00:00 UTC.
17. Set an **xAI spend limit** ([Billing → API spend management](https://docs.x.ai/console/billing)): keep invoiced billing at `$0` (prepaid only) or set a monthly top-up maximum you will notice. Voice Agent audio and STT are billed at the API rate.

## C — No second card

18. Setup keeps account SID, TeXML app id, and collection id in the session. Do **not** paste them into Plugins → Configure.

## Verify

19. **End-user path (in chat).** After install or a plugin update, start a **new** conversation. Grok Bot's `/workspace` is the cloud VM, not this repo — if the xAI connector errors with `Cannot find module '/workspace/scripts/xai-mcp.mjs'`, the plugin is an older build; update to 0.3.3+ and start a new conversation. Ask the Bot to check through Telnyx MCP and the PhoneZero xAI MCP (not curl, not the agent shell):
    - Telnyx auth works (a real `tools/call` succeeds);
    - `get_call_config` returns From last-4 (or Telnyx `list_phone_numbers` shows the DID);
    - a TeXML application named PhoneZero exists and the DID's `connection_id` matches it;
    - Telnyx outbound voice profile **PhoneZero US-only** `whitelisted_destinations` is listed (change countries there, not on the Configure card);
    - xAI MCP `ensure_collection` finds **PhoneZero bookings** (403 + "Zero Data Retention" → wrong team);
    - xAI MCP `list_phone_numbers` shows the DID as `origin=byo_trunk` with an `agentId` (missing agent is a warning — finish step 14–15).
20. **Optional developer path.** [`scripts/setup-check.sh`](../scripts/setup-check.sh) is developer-only. Run it on a **personal machine that is allowed to hold keys**, never on the Bot computer. It verifies Telnyx auth, that the number is on the account, that the TeXML application exists, and that the DID is attached to that app. If `XAI_API_KEY` is set, it also checks xAI BYO registration. It does **not** verify that the agent answers.
21. **Test call.** Use a **new** conversation after install or a plugin update (same rule as step 19).
    1. Ask the Bot to call **your** phone (`/book-table` or a setup-test). Facts go in `phonezero-task.json` on the collection — do **not** edit the Builder console. The `<Dial>` number is your E.164. Owner setup-test calls skip the hours guard (see [`plugins/phonezero/skills/phonezero-runtime/SKILL.md`](../plugins/phonezero/skills/phonezero-runtime/SKILL.md)).
    2. Wait for an explicit **yes** in chat before it places the call. Dial is Telnyx MCP + [`plugins/phonezero/texml/bridge.xml`](../plugins/phonezero/texml/bridge.xml) (Pause 3s then Dial). Not `place-call.sh`.
    3. After the call, the Bot polls for completion, fetches the recording `media_url` through Telnyx MCP (download promptly — the presigned URL expires in ~10 minutes), transcribes with the PhoneZero xAI MCP `transcribe`. Download audio to `/tmp` only — never copy recordings into the repo. Keep the Telnyx recording. Delete the live brief (`delete_booking`), not templates. Only then treat setup as done.

    Scripts (`provision.sh`, `setup-check.sh`, `place-call.sh`, `get-outcome.sh`) stay under the developer-key rule in step 20 — never as the end-user verify path. Never `source ~/.phonezero/env` in chat.

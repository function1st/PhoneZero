# PhoneZero — agent bootstrap

PhoneZero is a phone-skills platform (Telnyx hosted MCP + xAI Voice Agent) with zero user infrastructure. Restaurant booking is the first skill.

If the user pointed you at `https://github.com/function1st/PhoneZero` or said **set this up** / **set up phone calling** / `/setup-phone-calling`: identify the host, then run **only** that host’s section. Do not mix them.

| You are | If |
|---|---|
| **Grok Bot** | This is a Grok Bot / cloud chat, `/workspace` exists, or they attached this GitHub URL to a Bot |
| **Cursor IDE** | Local Cursor on their machine |

---

## Grok Bot — set this up

You are a **computer-use** agent. Drive the UI yourself. Do these steps **in order**. Do not treat missing package names as missing APIs. Do not hunt the Telnyx catalog for `whoami` or `/v2/whoami` — they are not MCP tools.

[README.md](README.md) has the same playbook at the top. After the ids are in session: [`plugins/phonezero/skills/phonezero-runtime/SKILL.md`](plugins/phonezero/skills/phonezero-runtime/SKILL.md) (dial + Grok ad-hoc interview) and the matching phone skill ([`book-restaurant`](plugins/phonezero/skills/book-restaurant/SKILL.md) or [`confirm-business-hours`](plugins/phonezero/skills/confirm-business-hours/SKILL.md)). How-to: [`docs/SKILLS.md`](docs/SKILLS.md).

**Do not** Customize → **+ Add** this repo as a Cursor plugin. Cursor **PhoneZero** (`plugins/phonezero`) is stdio Telnyx → on Grok the key never arrives → Telnyx **10009**.

**Do not** click **Authenticate**. Telnyx has no sign-in.

**Do not** put keys in chat. Type them only into the MCP header / Edit Values / secret field. **Do not** `source ~/.phonezero/env`. **Do not** run `scripts/provision.sh` here.

### 0. Vendor gate

Need: Telnyx KYC + US DID + Telnyx key; xAI team **ZDR off** + that team’s key; Builder at console.x.ai (unless they already said xAI is set up). If missing, stop.

### 1. Call identity — ask in chat, wait

Do **not** silently keep defaults. “Set this up” is not consent to these. Show this card and wait for a reply. **Do not ask for destination countries** — those live on Telnyx (step 6).

```
Call settings (defaults — change any now)

1. Spoken name the callee hears: PhoneZero
 “Hello, this is {name}…” — keep PhoneZero, or set your name / an alias.

2. AI disclaimer in the opener: ON
   ON  → “…{name}, an automated assistant, calling on a recorded line…”
   OFF → omit “, an automated assistant,”
   You may turn this OFF.
```

Keep their answers in session and put them on each `phonezero-task` (`spoken_name`, `disclose_ai`). Do **not** put name or disclose on the Configure / Edit Values card. If they turn disclaimer OFF and the Builder agent already exists, re-paste `prompts/voice-agent.md` once with `{disclosure_clause}` empty — that paste is the only way to change a baked prompt. Per-call they may still pick a different spoken name.

### 2. Uninstall the wrong plugin

If Cursor **PhoneZero** / `function1st-phonezero` is installed, Uninstall it.

### 3. Wire Telnyx HTTP

If `list_api_endpoints` already returns a real list, skip to **4**.

Customize → **MCPs** → add **HTTP** (not stdio, not `npx`):

| Field | Value |
|---|---|
| Name | `telnyx` |
| URL | `https://api.telnyx.com/v2/mcp` |
| Header | `Authorization` = `Bearer ` + key **in that form** |

If Grok-native **phonezero-grok** is available (not Cursor + Add): install it, **Edit Values** for `TELNYX_API_KEY`, From, `XAI_API_KEY` only. If a secret field needs the human, open that field and let them type.

[`.grok/config.toml`](.grok/config.toml) is the same HTTP Telnyx for hosts that load project Grok MCP.

### 4. Prove Telnyx

Call `list_api_endpoints`. Real endpoint list → **5**. `401` / **10009** / connection closed → fix the header; do not provision. “6 tools” / **Needs auth** prove nothing. Telnyx MCP is three generics (`list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`) plus app openers. There is **no** tool named `whoami`.

### 5. Wire xAI MCP (required)

Prefer the PhoneZero xAI MCP (8 tools). “No Grok xAI *package*” does **not** mean you cannot upload. Hosts are always `api.x.ai`.

- If `put_task` or `put_booking` is already listed → skip adding a connector.
- Else Customize → MCPs → **stdio** (not HTTP) name `xai`. Copy the `xai` block from [`plugins/phonezero/mcp.json`](plugins/phonezero/mcp.json) (same launcher is in [`plugins/phonezero-grok/.mcp.json`](plugins/phonezero-grok/.mcp.json)). Bind **real** values from secure fields: `XAI_API_KEY` or `PHONEZERO_CFG_XAI_API_KEY`, `PHONEZERO_FROM_NUMBER` or `PHONEZERO_CFG_FROM_NUMBER`. Do **not** leave literal `${…}` in env.

Prove: `get_call_config` (`xai_key_wired`, `from_wired`, From last-4) then `ensure_collection` (name `PhoneZero bookings`).

If they said Builder / collection / BYO is **already set up**: do **not** open console.x.ai. Ignore the wizard xAI number. Continue.

**Fallback** only if that stdio server will not start: stored xAI secret as Bearer on `https://api.x.ai/v1` and `/v2`. Sequence is `putBooking` / `transcribe` in [`plugins/phonezero/scripts/xai-mcp.mjs`](plugins/phonezero/scripts/xai-mcp.mjs). Never print the key. `403` + ZDR → stop.

### 6. Session ids — now, before any call plan

Keep these in session. Do **not** put them on a Configure card. Do **not** look them up after the user says yes.

1. **`TELNYX_ACCOUNT_SID`** — `invoke_api_endpoint` with `endpoint_name` `list_billing_groups` and args:

```json
{ "jq_filter": "[.data[].organization_id] | unique" }
```

Use that `organization_id`. (Developer curl `GET /v2/whoami` is the same value. It is **not** in the MCP catalog.)

2. **`PHONEZERO_TEXML_APP_ID`** — `invoke_api_endpoint` with `endpoint_name` `list_texml_applications` and args:

```json
{ "filter": { "friendly_name": "PhoneZero" }, "jq_filter": ".data[] | {id, friendly_name}" }
```

If a row named `PhoneZero` exists, use its `id`. If not, create it in **7**.

3. **From** — `get_call_config`. If `from_wired` is false, Telnyx `list_phone_numbers` for the DID on the PhoneZero TeXML app.

4. **Destinations** — read Telnyx, do not invent a PhoneZero field. `invoke_api_endpoint` `list_outbound_voice_profiles` args:

```json
{ "filter": { "name": { "contains": "PhoneZero" } }, "jq_filter": ".data[] | select(.name==\"PhoneZero US-only\") | {id, name, whitelisted_destinations}" }
```

Show the codes in chat: “Telnyx outbound voice profile **PhoneZero US-only** currently allows: … . Change this in Telnyx Mission Control → Voice → Outbound voice profiles (or ask me to PATCH). It is not a PhoneZero plugin setting.” Only PATCH if they ask to add/remove countries. Do not give legal advice.

### 7. Provision only if missing

If profile **PhoneZero US-only**, TeXML app **PhoneZero**, and the DID is already attached: skip create. Do **not** overwrite an existing `whitelisted_destinations` unless they asked to change countries. Approve each credentialed write. Never echo keys.

If something is missing, skill **Setup** via MCP names (not REST path names): `list_outbound_voice_profiles` / `create_outbound_voice_profiles` (name `PhoneZero US-only`, `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck`, `whitelisted_destinations` default `["US"]` on create, `daily_spend_limit="5.00"`, `daily_spend_limit_enabled=true`); `create_texml_applications` / `update_texml_applications` (`voice_url` = `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`, verify HTTP 200, `voice_method=get`); `update_phone_numbers` `connection_id` = TeXML app id.

xAI: `list_phone_numbers` → `register_byo_number` if the DID is not `byo_trunk` → `attach_agent` onto **your** DID. Skip Builder if they said already set up.

### 8. Calls

You already have SID, TeXML id, From, spoken name, disclose, and the Telnyx destination list. Read `phonezero-runtime` (plan-first, two attempts, `succeeded` / `booked` only with a live-person confirmation in the transcript). Match a shipped skill, or **interview into a `phonezero-task`** — do not ask them to paste a `SKILL.md` or write `~/.cursor/skills`. Owner setup-test to **their own confirmed number** may skip the hours guard — restaurants may not. The call plan must show Spoken as and only dial countries on that Telnyx whitelist. Per-call they may still override the spoken name. If they ask to save the shape as a template, pick memory or `put_template` and say where it went.

On explicit yes, in this order — do not resolve SID again:

1. `put_task` (or `put_booking` alias) — wait until processed
2. `invoke_api_endpoint` `calls_accounts_texml_calls` (runtime Dial JSON; `account_sid` + `ApplicationSid` from session)
3. Poll `retrieve_calls_accounts_texml_calls`
4. `retrieve_recordings_json_calls_accounts_texml_recordings_json` (not the write-named twin)
5. `transcribe` — do not paste the audio URL
6. Classify, then `delete_booking` (live brief only). Keep the Telnyx recording.

---

## Cursor IDE — set this up

1. Read [`plugins/phonezero/skills/phonezero-runtime/SKILL.md`](plugins/phonezero/skills/phonezero-runtime/SKILL.md) and [`plugins/phonezero/skills/book-restaurant/SKILL.md`](plugins/phonezero/skills/book-restaurant/SKILL.md) in full. Commands: `/setup-phone-calling`, `/book-table`, `/book-restaurant`, `/confirm-business-hours`. Local skills: [`docs/SKILLS.md`](docs/SKILLS.md).
2. Install the **Cursor** package only: [`.cursor-plugin/marketplace.json`](.cursor-plugin/marketplace.json) → [`plugins/phonezero/`](plugins/phonezero/). Channels: Customize → **+ Add** this repo root; Cursor Marketplace; copy `plugins/phonezero/` to `~/.cursor/plugins/local/phonezero`; or Team Marketplace import. Telnyx is stdio `npx @telnyx/mcp` + Configure `TELNYX_API_KEY`. Do **not** add hosted-HTTP Telnyx in this package (SSE GET 404 tombstone).
3. Configure card: `TELNYX_API_KEY`, `PHONEZERO_FROM_NUMBER`, `XAI_API_KEY` (ZDR **off**) only. Spoken name and disclose are per-task (chat), not this card. Destinations are the Telnyx voice-profile whitelist. Do not put account SID, TeXML id, or collection id on the card. New conversation after install. Verify with `list_api_endpoints` and `get_call_config`.
4. Then run the skill Setup (Telnyx MCP + xAI MCP + Builder once). Session SID is MCP `list_billing_groups` → `organization_id` (not a `whoami` tool).

Human walkthrough: [`docs/SETUP.md`](docs/SETUP.md). `scripts/provision.sh` is developer-only on a personal machine — never here.

---

## Both hosts

- Never commit or echo keys. Configure / Edit Values / MCP headers only — not the agent shell.
- Builder prompt is static. Brief each call with `phonezero-task.json` in the xAI collection — no TeXML `<Say>`, no per-call Builder edit. Re-paste `prompts/voice-agent.md` and `prompts/end_call.md` if the agent still searches `phonezero-booking.json`.
- An old chat missing new MCP tools is not a failure — new conversation after install.

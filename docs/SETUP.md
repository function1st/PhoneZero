# PhoneZero setup

This is the human-readable version of what Grok Bot automates when you ask *"Set up phone calling."* Approve each credentialed step. UIs move; the invariants are a US DID, that same DID registered with xAI as `byo_trunk`, a TeXML application whose `voice_url` is the inbound reject page (outbound calls carry **inline Texml**, not a hosted bin), a Builder voice agent attached to that number, spend caps on both vendors, the Telnyx key stored only as a Cursor plugin variable, and `XAI_API_KEY` entered once via Grok Bot's secure secret request. Runtime: `POST https://api.x.ai/v1/stt`. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Telnyx cannot transcribe Dial-verb recordings; the outcome path is recording `media_url` via Telnyx MCP → xAI `POST /v1/stt` (multichannel).

Fixture numbers in this guide are reserved (`+15555550100`-style). Never commit a real number. You do **not** buy a second number: `PHONEZERO_XAI_SIP_NUMBER` is normally the **same** DID as `PHONEZERO_FROM_NUMBER`, registered with xAI. A distinct fixture such as `+15555550101` is only an example value.

`TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` are created during provision — they are **not** required to install the plugin. Enter keys first (A), provision (B), then paste the remaining ids (C).

## Manual: Telnyx account, KYC, DID

1. Create a [Telnyx](https://telnyx.com/) account. Use a **dedicated** account for PhoneZero if you can — plugins are account-wide, so isolation lives at the vendor.
2. Complete Telnyx KYC / identity verification. This is the slowest step; start it first. Outbound voice stays blocked until it clears.
3. Buy one **US** DID (Mission Control → Numbers). This becomes `PHONEZERO_FROM_NUMBER` and, after registration, `PHONEZERO_XAI_SIP_NUMBER`. Example fixture only: `+15555550100`.

## A — Keys first

The Telnyx hosted MCP cannot run until `TELNYX_API_KEY` is saved as a plugin variable.

4. Create an [xAI](https://x.ai/) developer account with access to **Voice Agent Builder**.
5. Install the PhoneZero plugin from the Cursor Marketplace (this is also the Grok Bot channel), **or** clone this repo and install from the repo URL until the Marketplace listing exists. Open **Plugins → Configure**.
6. Enter these plugin variables now (not the provisioned ids):
   - `TELNYX_API_KEY` — **as a plugin variable**, not in chat and not in a file on the Bot computer. Grok Bot docs: hosted-MCP tokens stay with Cursor's backend, which runs those tool calls on the computer's behalf. The computer never stores those tokens.
   - `PHONEZERO_FROM_NUMBER`
   - `PHONEZERO_AGENT_NAME`
   - `PHONEZERO_DISCLOSE_AI` (boolean, default true)
   - `PHONEZERO_XAI_SIP_NUMBER` — set it to the same value as `PHONEZERO_FROM_NUMBER` (one DID).
7. Enter `XAI_API_KEY` through Grok Bot's **secure secret request** flow — a masked prompt that writes the value into the Bot environment without putting it in the chat transcript or model context. Runtime: `POST https://api.x.ai/v1/stt`. Setup: `GET`/`POST`/`PATCH https://api.x.ai/v2/phone-numbers`. Do not paste API keys in chat. Do not add `XAI_API_KEY` as a plugin variable.
8. Once `TELNYX_API_KEY` is saved, the Telnyx hosted MCP works. Leave `TELNYX_ACCOUNT_SID` and `PHONEZERO_TEXML_APP_ID` empty until phase C.

These are the only configuration names PhoneZero uses. The plugin variables must match `.cursor-plugin/plugin.json`. `XAI_API_KEY` is **not** a plugin variable (it is not referenced by the MCP config).

| Name | Kind | When | Purpose |
|---|---|---|---|
| `TELNYX_API_KEY` | plugin variable (secret) | A | Bearer token for the Telnyx hosted MCP. Cursor backend only. |
| `PHONEZERO_FROM_NUMBER` | plugin variable | A | Telnyx US DID (E.164), outbound caller ID. |
| `PHONEZERO_AGENT_NAME` | plugin variable | A | Spoken name. Substituted once into the Builder prompt; also in each spoken brief. |
| `PHONEZERO_DISCLOSE_AI` | plugin variable (boolean, default true) | A | Setup-time prompt substitution + each spoken brief. |
| `PHONEZERO_XAI_SIP_NUMBER` | plugin variable | A (same as FROM) | DID registered with xAI as `byo_trunk`. Call-create `To` (the agent answers first). |
| `XAI_API_KEY` | out-of-band env secret | A | Runtime STT + setup phone-numbers API. Secure-secret flow. Not in `plugin.json`. |
| `TELNYX_ACCOUNT_SID` | plugin variable | C | TeXML REST account SID (`GET /v2/whoami` → `data.organization_id`). Find it: `curl -sSg -H "Authorization: Bearer $TELNYX_API_KEY" https://api.telnyx.com/v2/whoami`. |
| `PHONEZERO_TEXML_APP_ID` | plugin variable | C | TeXML application SID. |

## B — Provision

Account, KYC, and the DID stay manual. Everything after that is API-automatable.

9. **End-user path.** Ask the Bot: *"Set up phone calling."* The Bot uses the Telnyx hosted MCP (`list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`) and `XAI_API_KEY` for the xAI phone-numbers API. Approve each credentialed step. It will:
   - Resolve `TELNYX_ACCOUNT_SID` from `GET /v2/whoami` (`data.organization_id`).
   - Find-or-create outbound voice profile **PhoneZero US-only**: `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck` (the only accepted combo today; error 10015 otherwise), `whitelisted_destinations=["US"]`, `daily_spend_limit="5.00"`, `daily_spend_limit_enabled=true`.
   - Find-or-create TeXML application **PhoneZero** with `voice_url` = [`texml/inbound.xml`](../texml/inbound.xml) (default raw URL: `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`) and `voice_method=get`. **Verify that URL returns HTTP 200 before writing it.** Until `texml/inbound.xml` is on `main`, set `PHONEZERO_INBOUND_XML_URL` to your fork/branch raw URL. That URL is fetched **only for inbound** calls to the DID. Outbound restaurant calls carry inline `Texml` (template [`texml/bridge.xml`](../texml/bridge.xml)).
   - Attach the DID: `PATCH /v2/phone_numbers/{phone_number_id}` `{"connection_id":"<texml_app_id>"}`.
   - Register the DID with xAI if it is not already registered: `POST https://api.x.ai/v2/phone-numbers` `{"name":"PhoneZero","phoneNumber":"+1…","origin":"byo_trunk"}`.

10. **Developer path.** On a **personal machine that is allowed to hold keys**, never on the Bot computer, run [`scripts/provision.sh`](../scripts/provision.sh). Same work, idempotent (check-before-create). `--dry-run` prints the plan without POST/PATCH. Optional env:
    - `PHONEZERO_INBOUND_XML_URL` — override the default raw inbound.xml URL (required if the default 404s).
    - `PHONEZERO_XAI_SIP_NUMBER` — defaults to `PHONEZERO_FROM_NUMBER`.
    - `XAI_API_KEY` — register the DID with xAI.
    - `PHONEZERO_XAI_AGENT_ID` — attach a Builder agent (step 12) via the fieldMask PATCH.

11. **Create the Builder agent (once).** There is no public API (`/v1/agents` is not enabled). Preferred: the Bot opens Voice Agent Builder in its own browser with your approved console session, creates one agent, pastes [`prompts/voice-agent.md`](../prompts/voice-agent.md) **fully substituted once** (`{agent_name}` = `PHONEZERO_AGENT_NAME`; `{disclosure_clause}` = `, an automated assistant,` if `PHONEZERO_DISCLOSE_AI` is on, else empty), saves, and copies the `agentId`. Fallback: you do those same steps in the console and give the Bot the `agentId`. The prompt is fully static after that — **no TASK BRIEF maintenance, ever.** The console is never touched at call time; each reservation is briefed by voice in TeXML `<Say>`.
12. Configure Builder **guardrails** once (if the console exposes them): stay inside the booked window, verbatim read-back before accepting, no invented confirmation, hang up politely on recording or AI objection, spoken recap in the grammar the prompt specifies.
13. **Attach the agent** to the registered number. API (preferred): `PATCH https://api.x.ai/v2/phone-numbers/{phoneNumberId}` body `{"phoneNumber":{"agentId":"agent_…"},"fieldMask":{"paths":["agent_id"]}}` — protobuf FieldMask style; a flat `{"agentId":…}` is rejected. `provision.sh` does this when `PHONEZERO_XAI_AGENT_ID` is set. Or attach in the Builder console.
14. Set a **Telnyx spend cap** on the outbound voice profile (enable daily spend limit; `provision.sh` sets `$5.00`). Caps reset 00:00 UTC. This is the server-side brake — the skill cannot enforce spend itself.
15. Set an **xAI spend limit** in the console ([Billing → API spend management](https://docs.x.ai/console/billing)): keep invoiced billing at `$0` (prepaid only) or set a monthly top-up maximum you will notice. Voice Agent audio and STT are billed at the API rate.

## C — Enter remaining vars

16. Copy the ids printed by the Bot or `provision.sh` into **Plugins → Configure**:
    - `TELNYX_ACCOUNT_SID`
    - `PHONEZERO_TEXML_APP_ID`

## Verify

17. **End-user path (in chat, via the Telnyx MCP).** Do not export `TELNYX_API_KEY` onto the Bot computer. Ask the Bot to check, through MCP tools only:
    - auth works (account/balance call succeeds);
    - `PHONEZERO_FROM_NUMBER` is present on the account;
    - the TeXML application `PHONEZERO_TEXML_APP_ID` exists;
    - the DID's `connection_id` matches `PHONEZERO_TEXML_APP_ID`;
    - if `XAI_API_KEY` is in the environment: `GET https://api.x.ai/v2/phone-numbers` shows the DID registered with `origin=byo_trunk`, and whether an `agentId` is attached (missing agent is a warning — create it in Builder).
18. **Optional developer path.** [`scripts/setup-check.sh`](../scripts/setup-check.sh) is developer-only. Run it on a **personal machine that is allowed to hold keys**, never on the Bot computer. It verifies Telnyx auth, that the number is on the account, that the TeXML application exists, and that the DID is attached to that app. If `XAI_API_KEY` is set, it also checks xAI BYO registration. It does **not** verify that the agent answers.
19. **Test call.**
    1. Ask the Bot to call **your** phone. The spoken brief should say this is a test and that the callee is the owner. The restaurant number in `<Dial>` is your E.164. Do **not** edit the Builder console.
    2. Wait for an explicit **yes** in chat before it places the call.
    3. After the call, the Bot polls for completion, fetches the recording `media_url` through Telnyx MCP (download promptly — the presigned URL expires in ~10 minutes), transcribes with xAI STT (`POST /v1/stt`, multichannel). You should hear the briefing first, then the opener. Confirm the spoken recap appears in that transcript. Only then treat setup as done.

    Scripts (`provision.sh`, `setup-check.sh`, `place-call.sh`, `get-outcome.sh`) stay under the developer-key rule in step 18 — never as the end-user verify path on the Bot computer.

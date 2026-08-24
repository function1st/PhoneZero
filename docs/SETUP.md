# PhoneZero setup

This is the human-readable version of what Grok Bot automates when you ask *"Set up phone calling."* Approve each credentialed step. UIs move; the invariants are a US DID, that same DID registered with xAI as `byo_trunk`, a TeXML application whose `voice_url` is the inbound reject page (outbound calls carry **inline Texml**, not a hosted bin), a Builder voice agent attached to that number, spend caps on both vendors, the Telnyx key stored only as a Cursor plugin variable, and `XAI_API_KEY` entered once via Grok Bot's secure secret request (runtime: STT; setup: xAI phone-number API). Telnyx cannot transcribe Dial-verb recordings; the outcome path is recording `media_url` via Telnyx MCP → xAI `POST /v1/stt` (multichannel).

Fixture numbers in this guide are reserved (`+15555550100`-style). Never commit a real number. You do **not** buy a second number: `PHONEZERO_XAI_SIP_NUMBER` is normally the **same** DID as `PHONEZERO_FROM_NUMBER`, registered with xAI. A distinct fixture such as `+15555550101` is only an example value.

## Telnyx (account, KYC, DID — manual)

1. Create a [Telnyx](https://telnyx.com/) account. Use a **dedicated** account for PhoneZero if you can — plugins are account-wide, so isolation lives at the vendor.
2. Complete Telnyx KYC / identity verification. This is the slowest step; start it first. Outbound voice stays blocked until it clears.
3. Buy one **US** DID (Mission Control → Numbers). This becomes `PHONEZERO_FROM_NUMBER` and, after registration, `PHONEZERO_XAI_SIP_NUMBER`. Example fixture only: `+15555550100`.

## Provision (Bot via MCP, or developer script)

Account, KYC, and the DID stay manual. Everything after that is API-automatable.

4. **End-user path.** Ask the Bot: *"Set up phone calling."* The Bot uses the Telnyx hosted MCP (`list_api_endpoints` → `get_api_endpoint_schema` → `invoke_api_endpoint`) and, once `XAI_API_KEY` is in the environment, the xAI phone-numbers API. Approve each credentialed step. It will:
   - Resolve `TELNYX_ACCOUNT_SID` from `GET /v2/whoami` (`data.organization_id`).
   - Find-or-create outbound voice profile **PhoneZero US-only**: `traffic_type=conversational`, `service_plan=global`, `usage_payment_method=rate-deck` (the only accepted combo today; error 10015 otherwise), `whitelisted_destinations=["US"]`, daily spend cap enabled.
   - Find-or-create TeXML application **PhoneZero** with `voice_url` = [`texml/inbound.xml`](../texml/inbound.xml) (default raw URL: `https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml`) and `voice_method=get`. That URL is fetched **only for inbound** calls to the DID. Outbound restaurant calls carry inline `Texml` (template [`texml/bridge.xml`](../texml/bridge.xml)).
   - Attach the DID: `PATCH /v2/phone_numbers/{phone_number_id}` `{"connection_id":"<texml_app_id>"}`.
   - Register the DID with xAI if it is not already registered: `POST https://api.x.ai/v2/phone-numbers` `{"name":"PhoneZero","phoneNumber":"+1…","origin":"byo_trunk"}`.

5. **Developer path.** On a **personal machine that is allowed to hold keys**, never on the Bot computer, run [`scripts/provision.sh`](../scripts/provision.sh). Same work, idempotent (check-before-create). `--dry-run` prints the plan without POST/PATCH. Optional env:
   - `PHONEZERO_INBOUND_XML_URL` — override the default raw inbound.xml URL.
   - `PHONEZERO_XAI_SIP_NUMBER` — defaults to `PHONEZERO_FROM_NUMBER`.
   - `XAI_API_KEY` — register the DID with xAI.
   - `PHONEZERO_XAI_AGENT_ID` — attach a Builder agent (step 9) via the fieldMask PATCH.

## xAI Voice Agent Builder (agent creation is console-only)

6. Create an [xAI](https://x.ai/) developer account with access to **Voice Agent Builder**.
7. In Voice Agent Builder, create one agent. Use [`prompts/voice-agent.md`](../prompts/voice-agent.md) as the system prompt. Copy the `agentId` (`agent_…`) from the Builder console (it also appears on `GET https://api.x.ai/v2/phone-numbers` once attached). Set `PHONEZERO_AGENT_NAME` to the spoken name in the opener. Leave `PHONEZERO_DISCLOSE_AI` on unless you have a reason to toggle it. There is no public API for agent creation (`/v1/agents` is not enabled).
8. Configure Builder **guardrails**: stay inside the booked window, verbatim read-back before accepting, no invented confirmation, hang up politely on recording or AI objection, spoken recap in the grammar the prompt specifies.
9. **Attach the agent** to the registered number. API (preferred): `PATCH https://api.x.ai/v2/phone-numbers/{phoneNumberId}` body `{"phoneNumber":{"agentId":"agent_…"},"fieldMask":{"paths":["agent_id"]}}` — protobuf FieldMask style; a flat `{"agentId":…}` is rejected. `provision.sh` does this when `PHONEZERO_XAI_AGENT_ID` is set. Or attach in the Builder console. Store the registered E.164 as `PHONEZERO_XAI_SIP_NUMBER` — normally identical to `PHONEZERO_FROM_NUMBER`.

## Spend caps

10. Set a **Telnyx spend cap** on the outbound voice profile (enable daily spend limit; `provision.sh` sets `$5.00`). Caps reset 00:00 UTC. This is the server-side brake — the skill cannot enforce spend itself.
11. Set an **xAI spend limit** in the console ([Billing → API spend management](https://docs.x.ai/console/billing)): keep invoiced billing at `$0` (prepaid only) or set a monthly top-up maximum you will notice. Voice Agent audio and STT are billed at the API rate.

## Plugin variables and the STT secret

These are the only configuration names PhoneZero uses. The seven plugin variables must match `.cursor-plugin/plugin.json`. `XAI_API_KEY` is **not** a plugin variable (it is not referenced by the MCP config).

| Name | Kind | Purpose |
|---|---|---|
| `TELNYX_API_KEY` | plugin variable (secret) | Bearer token for the Telnyx hosted MCP. Cursor backend only. |
| `TELNYX_ACCOUNT_SID` | plugin variable | TeXML REST account SID. Developer scripts may leave it unset (auto-resolved via `GET /v2/whoami` → `data.organization_id`). Must be entered as a plugin variable for Grok Bot. Find it: `curl -sS -H "Authorization: Bearer $TELNYX_API_KEY" https://api.telnyx.com/v2/whoami`. |
| `PHONEZERO_FROM_NUMBER` | plugin variable | Telnyx US DID (E.164), outbound caller ID. |
| `PHONEZERO_TEXML_APP_ID` | plugin variable | TeXML application SID. |
| `PHONEZERO_XAI_SIP_NUMBER` | plugin variable | Same DID as `PHONEZERO_FROM_NUMBER`, registered with xAI as `byo_trunk`. Substituted into the inline Texml SIP URI at call time. |
| `PHONEZERO_AGENT_NAME` | plugin variable | Spoken name in the opener. |
| `PHONEZERO_DISCLOSE_AI` | plugin variable (boolean, default true) | Include the automated-assistant clause. |
| `XAI_API_KEY` | out-of-band env secret | xAI key for `POST /v1/stt` (runtime) and `https://api.x.ai/v2/phone-numbers` (setup). Secure-secret flow. Not in `plugin.json`. |

12. Install the PhoneZero plugin from the Cursor Marketplace (this is also the Grok Bot channel). Open **Plugins → Configure** for PhoneZero.
13. Enter every plugin variable in the table above. Put the Telnyx API key in `TELNYX_API_KEY` **as a plugin variable**, not in chat and not in a file on the Bot computer. Grok Bot docs: hosted-MCP tokens stay with Cursor's backend, which runs those tool calls on the computer's behalf. The computer never stores those tokens.
14. Enter `XAI_API_KEY` through Grok Bot's **secure secret request** flow — a masked prompt that writes the value into the Bot environment without putting it in the chat transcript or model context. The Bot uses it for the one `POST /v1/stt` call per task (multichannel, on the recording fetched from Telnyx) and, during setup, the xAI phone-numbers API. Do not paste API keys in chat: chat is logged, may be used as model context, and is the wrong place for a credential. Do not add `XAI_API_KEY` as a plugin variable.

## Verify

15. **End-user path (in chat, via the Telnyx MCP).** Do not export `TELNYX_API_KEY` onto the Bot computer. Ask the Bot to check, through MCP tools only:
    - auth works (account/balance call succeeds);
    - `PHONEZERO_FROM_NUMBER` is present on the account;
    - the TeXML application `PHONEZERO_TEXML_APP_ID` exists;
    - the DID's `connection_id` matches `PHONEZERO_TEXML_APP_ID`;
    - if `XAI_API_KEY` is in the environment: `GET https://api.x.ai/v2/phone-numbers` shows the DID registered with `origin=byo_trunk`, and whether an `agentId` is attached (missing agent is a warning — create it in Builder).
16. **Optional developer path.** [`scripts/setup-check.sh`](../scripts/setup-check.sh) is developer-only. Run it on a **personal machine that is allowed to hold keys**, never on the Bot computer. It verifies Telnyx auth, that the number is on the account, that the TeXML application exists, and that the DID is attached to that app. If `XAI_API_KEY` is set, it also checks xAI BYO registration. It does **not** verify that the agent answers.
17. **Test call.**
    1. In Voice Agent Builder, update the **TASK BRIEF** with a test brief: your name, **your** phone as the "restaurant", and a note that this is a test.
    2. Ask the Bot to dial your own E.164 via the Telnyx MCP. Wait for an explicit **yes** in chat before it places the call.
    3. After the call, the Bot polls for completion, fetches the recording `media_url` through Telnyx MCP (download promptly — the presigned URL expires in ~10 minutes), transcribes with xAI STT (`POST /v1/stt`, multichannel), and you confirm the spoken recap appears in that transcript. Only then treat setup as done.

    Scripts (`provision.sh`, `setup-check.sh`, `place-call.sh`, `get-outcome.sh`) stay under the developer-key rule in step 16 — never as the end-user verify path on the Bot computer.

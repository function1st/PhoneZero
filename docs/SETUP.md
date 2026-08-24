# PhoneZero setup

This is the human-readable version of what Grok Bot automates when you ask *"Set up phone calling."* Approve each credentialed step. UIs move; the invariants are a US DID, that same DID registered with xAI as Direct SIP, a TeXML application pointed at a bin that bridges to `sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls`, a Builder voice agent on that number, spend caps on both vendors, the Telnyx key stored only as a Cursor plugin variable, and `XAI_API_KEY` entered once via Grok Bot's secure secret request (used only for STT). Telnyx cannot transcribe Dial-verb recordings; the outcome path is recording `media_url` via Telnyx MCP → xAI `POST /v1/stt` (multichannel).

Fixture numbers in this guide are reserved (`+15555550100`-style). Never commit a real number. You do **not** buy a second number: `PHONEZERO_XAI_SIP_NUMBER` is normally the **same** DID as `PHONEZERO_FROM_NUMBER`, registered with xAI. A distinct fixture such as `+15555550101` is only an example value.

## Telnyx (account, DID, application)

1. Create a [Telnyx](https://telnyx.com/) account. Use a **dedicated** account for PhoneZero if you can — plugins are account-wide, so isolation lives at the vendor.
2. Complete Telnyx KYC / identity verification. This is the slowest step; start it first. Outbound voice stays blocked until it clears.
3. Buy one **US** DID (Mission Control → Numbers). This becomes `PHONEZERO_FROM_NUMBER` and, after step 9, `PHONEZERO_XAI_SIP_NUMBER`. Example fixture only: `+15555550100`.
4. Create an **outbound voice profile** (Voice → Outbound Voice Profiles). Restrict allowed destinations to the US. Assign the profile to the TeXML application you create in the next step. See [Outbound Voice Profiles](https://developers.telnyx.com/docs/voice/sip-trunking/configuration/outbound-voice-profiles).
5. Create a **TeXML application** (Voice → Programmable Voice → TeXML Applications). Attach the DID from step 3 and the outbound voice profile from step 4. Copy the application ID into `PHONEZERO_TEXML_APP_ID`. Copy the account SID from Mission Control into `TELNYX_ACCOUNT_SID`. Do **not** paste the TeXML bin yet — the SIP number must exist first (step 9).

## xAI (agent + Direct SIP, before the bin)

6. Create an [xAI](https://x.ai/) developer account with access to **Voice Agent Builder**.
7. In Voice Agent Builder, create one agent. Use [`prompts/voice-agent.md`](../prompts/voice-agent.md) as the system prompt. Set `PHONEZERO_AGENT_NAME` to the spoken name in the opener. Leave `PHONEZERO_DISCLOSE_AI` on unless you have a reason to toggle it.
8. Configure Builder **guardrails**: stay inside the booked window, verbatim read-back before accepting, no invented confirmation, hang up politely on recording or AI objection, spoken recap in the grammar the prompt specifies.
9. **Register that same DID with xAI as Direct SIP.** In Voice Agent Builder, use **connect number via direct SIP**. The number must be registered with xAI per [SIP Phone Calls](https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech/sip) (customer-owned / BYO Direct SIP). Do **not** follow the Telnyx FQDN-trunk section of that page; PhoneZero's runtime path is TeXML `<Dial><Sip>`. Store the registered E.164 as `PHONEZERO_XAI_SIP_NUMBER` — normally identical to `PHONEZERO_FROM_NUMBER`.

## TeXML bin (after the SIP number exists)

10. Create a **TeXML bin** from [`texml/bridge.xml`](../texml/bridge.xml) (Voice → TeXML Bin → Create new). Paste the file, substitute the single placeholder below, save, and copy the bin URL into `PHONEZERO_TEXML_BIN_URL`. Point the TeXML application at that URL (Voice Method `GET`, field *Send a TeXML Webhook to the URL*). See [TeXML setup](https://developers.telnyx.com/docs/voice/programmable-voice/texml-setup).

    | Placeholder in `texml/bridge.xml` | Replace with | Plugin variable |
    |---|---|---|
    | `{PHONEZERO_XAI_SIP_NUMBER}` | The E.164 registered in step 9 (normally the same DID as `PHONEZERO_FROM_NUMBER`) | `PHONEZERO_XAI_SIP_NUMBER` |

    The published bin must contain `sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls` with the placeholder substituted — no leftover `{PHONEZERO_XAI_SIP_NUMBER}` token. The bin ships **dual-channel recording**. It does **not** ship AMD: AMD on `<Sip>` would classify the xAI agent, not the restaurant. Restaurant AMD is on the REST/MCP initiate-call body (`MachineDetection`, `AsyncAmd` true). Do not add a public webhook server.
11. Set a **Telnyx spend cap** on the outbound voice profile (enable daily spend limit; pick an amount you will notice). Caps reset 00:00 UTC. This is the server-side brake — the skill cannot enforce spend itself.
12. Set an **xAI spend limit** in the console ([Billing → API spend management](https://docs.x.ai/console/billing)): keep invoiced billing at `$0` (prepaid only) or set a monthly top-up maximum you will notice. Voice Agent audio and STT are billed at the API rate.

## Plugin variables and the STT secret

These are the only configuration names PhoneZero uses. The eight plugin variables must match `.cursor-plugin/plugin.json`. `XAI_API_KEY` is **not** a plugin variable (it is not referenced by the MCP config).

| Name | Kind | Purpose |
|---|---|---|
| `TELNYX_API_KEY` | plugin variable (secret) | Bearer token for the Telnyx hosted MCP. Cursor backend only. |
| `TELNYX_ACCOUNT_SID` | plugin variable | TeXML REST account SID. |
| `PHONEZERO_FROM_NUMBER` | plugin variable | Telnyx US DID (E.164), outbound caller ID. |
| `PHONEZERO_TEXML_APP_ID` | plugin variable | TeXML application SID. |
| `PHONEZERO_TEXML_BIN_URL` | plugin variable | Public URL of the TeXML bin. |
| `PHONEZERO_XAI_SIP_NUMBER` | plugin variable | Same DID as `PHONEZERO_FROM_NUMBER`, registered with xAI for Direct SIP. |
| `PHONEZERO_AGENT_NAME` | plugin variable | Spoken name in the opener. |
| `PHONEZERO_DISCLOSE_AI` | plugin variable (boolean, default true) | Include the automated-assistant clause. |
| `XAI_API_KEY` | out-of-band env secret | xAI key for `POST /v1/stt` only. Secure-secret flow. Not in `plugin.json`. |

13. Install the PhoneZero plugin from the Cursor Marketplace (this is also the Grok Bot channel). Open **Plugins → Configure** for PhoneZero.
14. Enter every plugin variable in the table above. Put the Telnyx API key in `TELNYX_API_KEY` **as a plugin variable**, not in chat and not in a file on the Bot computer. Grok Bot docs: hosted-MCP tokens stay with Cursor's backend, which runs those tool calls on the computer's behalf. The computer never stores those tokens.
15. Enter `XAI_API_KEY` through Grok Bot's **secure secret request** flow — a masked prompt that writes the value into the Bot environment without putting it in the chat transcript or model context. The Bot uses it solely for the one `POST /v1/stt` call per task (multichannel, on the recording fetched from Telnyx). Do not paste API keys in chat: chat is logged, may be used as model context, and is the wrong place for a credential. Do not add `XAI_API_KEY` as a plugin variable.

## Verify

16. **End-user path (in chat, via the Telnyx MCP).** Do not export `TELNYX_API_KEY` onto the Bot computer. Ask the Bot to check, through MCP tools only:
    - auth works (account/balance call succeeds);
    - `PHONEZERO_FROM_NUMBER` is present on the account;
    - the TeXML application `PHONEZERO_TEXML_APP_ID` exists;
    - `PHONEZERO_TEXML_BIN_URL` fetches publicly and the XML contains the SIP bridge `sip:{PHONEZERO_XAI_SIP_NUMBER}@sip.voice.x.ai;transport=tls` with no leftover `{PHONEZERO_XAI_SIP_NUMBER}` placeholder.
17. **Optional developer path.** [`scripts/setup-check.sh`](../scripts/setup-check.sh) is developer-only. Run it on a **personal machine that is allowed to hold keys**, never on the Bot computer. It verifies Telnyx auth, that the number is on the account, that the TeXML application exists, and that the bin content is the substituted SIP bridge. It does **not** verify xAI SIP registration or that the agent answers.
18. **Test call.**
    1. In Voice Agent Builder, update the **TASK BRIEF** with a test brief: your name, **your** phone as the "restaurant", and a note that this is a test.
    2. Ask the Bot to dial your own E.164 via the Telnyx MCP. Wait for an explicit **yes** in chat before it places the call.
    3. After the call, the Bot polls for completion, fetches the recording `media_url` through Telnyx MCP, transcribes with xAI STT (`POST /v1/stt`, multichannel), and you confirm the spoken recap appears in that transcript. Only then treat setup as done.

    Scripts (`setup-check.sh`, `place-call.sh`, `get-outcome.sh`) stay under the developer-key rule in step 17 — never as the end-user verify path on the Bot computer.

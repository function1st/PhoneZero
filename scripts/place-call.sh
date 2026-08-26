#!/usr/bin/env bash
# Developer tool for a personal machine that is allowed to hold API keys. The
# Grok Bot production path uses the Telnyx hosted MCP and never exports
# TELNYX_API_KEY into its environment.
#
# place-call.sh — curl equivalent of the Telnyx hosted MCP dial.
#
# Production path is the Telnyx hosted MCP:
#   invoke_api_endpoint endpoint_name=calls_accounts_texml_calls
# This script POSTs the same TeXML REST initiate-call request for local testing.
#
# Endpoint (verified):
#   POST https://api.telnyx.com/v2/texml/Accounts/{account_sid}/Calls
#   Request schema is oneOf: Url XOR Texml XOR neither.
#   https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
#
# Reversed flow (verified Aug 2026): To is the xAI agent SIP URI; Texml
# Pause+Dial(restaurant). Booking facts go in the xAI collection JSON
# (put-booking-file.sh), not Telnyx TTS. MachineDetection/AsyncAmd are
# omitted (they would classify the agent To-leg).
#
# TeXML REST uses PascalCase JSON keys (To / From / Texml).
# ApplicationSid is required. Recording is call-level (Record,
# RecordingChannels) — not in the XML.
#
# StatusCallback is omitted (zero-server).
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   PHONEZERO_FROM_NUMBER   — caller ID and SIP To (sip:{FROM}@sip.voice.x.ai;transport=tls)
#   PHONEZERO_TEXML_APP_ID
# Optional / auto-resolved:
#   TELNYX_ACCOUNT_SID — if unset, GET /v2/whoami → data.organization_id
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: place-call.sh [--dry-run] [--booking-json PATH] E.164_RESTAURANT

Place a TeXML call: To = the xAI agent SIP URI; Texml pauses then
dials the restaurant E.164. Booking facts must already be in the
xAI collection as phonezero-booking.json (or pass --booking-json to
upload first). Prints the Call SID.

Numbers must be E.164 (^\+[1-9][0-9]{6,14}$). PHONEZERO_FROM_NUMBER
must also be US (+1 and 10 digits). Restaurant dest is E.164 only —
Telnyx voice-profile `whitelisted_destinations` is country enforcement.

  --booking-json PATH  Upload this phonezero-booking JSON before dialing
  --dry-run            Print the request (API key redacted) without sending it

Required environment:
  TELNYX_API_KEY
  PHONEZERO_FROM_NUMBER              E.164 caller ID and SIP To
                                     (sip:{FROM}@sip.voice.x.ai;transport=tls)
  PHONEZERO_TEXML_APP_ID             TeXML Application id (ApplicationSid)

Optional / auto-resolved:
  TELNYX_ACCOUNT_SID                 if unset, GET /v2/whoami → data.organization_id
  PHONEZERO_XAI_SIP_NUMBER           SIP To E.164. Default is
                                     PHONEZERO_FROM_NUMBER (Telnyx DID).
                                     Set this when the agent answers an
                                     xAI-provisioned number instead.

Example (fixture number only):
  place-call.sh --booking-json /tmp/phonezero-booking.json +15555550100
  place-call.sh --dry-run +15555550100
EOF
}

# Country enforcement is the Telnyx voice profile. Scripts cannot map
# E.164 to a country reliably. From must be the US DID. Dest is E.164.
is_e164() {
  [[ "$1" =~ ^\+[1-9][0-9]{6,14}$ ]]
}

is_us_e164() {
  [[ "$1" =~ ^\+1[0-9]{10}$ ]]
}

require_number() {
  local name="$1"
  local num="$2"
  if ! is_e164 "$num"; then
    echo "error: ${name} must be E.164 (+ then 7-15 digits, e.g. +15555550100)" >&2
    exit 2
  fi
  if [ "$name" = "PHONEZERO_FROM_NUMBER" ] && ! is_us_e164 "$num"; then
    echo "error: ${name} must be a US E.164 DID (+1 and 10 digits, e.g. +15555550100)" >&2
    exit 2
  fi
}

urlencode() {
  VAL="$1" python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["VAL"], safe=""))'
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "error: $name is not set" >&2
    exit 2
  fi
}

# organization_id from GET /v2/whoami is the TeXML Accounts/{account_sid} value.
resolve_account_sid() {
  if [ -n "${TELNYX_ACCOUNT_SID:-}" ]; then
    return 0
  fi
  local tmp code org
  tmp="$(mktemp)"
  code="$(
    curl -sSg \
      -o "$tmp" \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${TELNYX_API_KEY}" \
      -H "Accept: application/json" \
      "https://api.telnyx.com/v2/whoami"
  )" || true
  if [ "$code" != "200" ]; then
    echo "error: GET /v2/whoami HTTP ${code} (cannot resolve TELNYX_ACCOUNT_SID)" >&2
    rm -f "$tmp"
    exit 2
  fi
  org="$(
    python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
org=(d.get("data") or {}).get("organization_id") or ""
if not isinstance(org, str) or not org.strip():
    sys.exit(1)
print(org.strip())
' <"$tmp"
  )" || {
    echo "error: GET /v2/whoami response missing data.organization_id" >&2
    rm -f "$tmp"
    exit 2
  }
  rm -f "$tmp"
  TELNYX_ACCOUNT_SID="$org"
  export TELNYX_ACCOUNT_SID
  echo "resolved TELNYX_ACCOUNT_SID via /v2/whoami (${TELNYX_ACCOUNT_SID:0:8}…)"
}

# Build inline Texml from texml/bridge.xml: substitute restaurant E.164,
# strip comments and whitespace. No <Say> — booking facts are the
# collection JSON. Fallback: proven shape.
build_texml() {
  python3 -c '
import os, re
from pathlib import Path
rest = os.environ["PHONEZERO_RESTAURANT"]
from_num = os.environ["PHONEZERO_FROM_NUMBER"]
minimal = (
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    "<Response>"
    "<Pause length=\"3\"/>"
    "<Dial callerId=\"%s\" timeout=\"60\" timeLimit=\"600\" ringTone=\"us\">"
    "<Number>%s</Number>"
    "</Dial>"
    "</Response>"
) % (from_num, rest)
path = os.environ.get("PHONEZERO_BRIDGE_XML") or ""
if not path or not Path(path).is_file():
    print(minimal)
    raise SystemExit(0)
xml = Path(path).read_text(encoding="utf-8")
xml = re.sub(r"<!--.*?-->", "", xml, flags=re.DOTALL)
xml = xml.replace("{RESTAURANT_E164}", rest)
xml = xml.replace("{PHONEZERO_FROM_NUMBER}", from_num)
xml = "".join(line.strip() for line in xml.splitlines())
xml = re.sub(r">\s+<", "><", xml)
if "{RESTAURANT_E164}" in xml or "{PHONEZERO_FROM_NUMBER}" in xml:
    raise SystemExit("error: unsubstituted placeholder in Texml")
if "<Say>" in xml:
    raise SystemExit("error: Texml must not include Say (booking JSON is the brief)")
if "<Dial" not in xml:
    raise SystemExit("error: Texml missing Dial after substitution")
print(xml)
'
}

# Build the PascalCase JSON body. python3 avoids interpolation bugs in XML.
# Field names verified against InitiateCallRequest. Texml is accepted by
# the live API even when some OpenAPI snapshots omit it (Url XOR Texml).
build_payload() {
  python3 -c '
import json, os
print(json.dumps({
    "To": os.environ["PHONEZERO_TO"],
    "From": os.environ["PHONEZERO_FROM_NUMBER"],
    "ApplicationSid": os.environ["PHONEZERO_TEXML_APP_ID"],
    # Inline TeXML (not a hosted bin). Do not also send Url.
    "Texml": os.environ["PHONEZERO_TEXML"],
    # Dual-channel recording is call-level (not a Dial attribute).
    "Record": True,
    "RecordingChannels": "dual",
    # No MachineDetection / AsyncAmd: they would classify the agent To-leg.
    # Seconds to wait for the agent To to answer. Range 5–120.
    "Timeout": 30,
    # Max call duration in seconds. Range 30–14400, default 14400.
    "TimeLimit": 600,
}, separators=(",", ":")))
'
}

# Pull a Call SID from the initiate response. Documented InitiateCallResult
# only lists from / to / status; the sibling AI-call result documents
# call_sid. Accept any of call_sid / sid / CallSid.
# https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
extract_call_sid() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("error: initiate-call response was not JSON\n")
    sys.exit(1)
if not isinstance(data, dict):
    sys.stderr.write("error: initiate-call response was not an object\n")
    sys.exit(1)
for key in ("call_sid", "sid", "CallSid"):
    value = data.get(key)
    if isinstance(value, str) and value:
        print(value)
        sys.exit(0)
sys.stderr.write(
    "error: no call_sid/sid/CallSid in response "
    "(InitiateCallResult schema only documents from/to/status; "
    "see https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call)\n"
)
sys.stderr.write(raw + "\n")
sys.exit(1)
'
}

DRY_RUN=0
RESTAURANT=""
BOOKING_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --booking-json)
      if [ $# -lt 2 ]; then
        echo "error: --booking-json requires a path" >&2
        exit 2
      fi
      BOOKING_JSON="$2"
      shift 2
      ;;
    --brief)
      echo "error: --brief is removed; booking facts are phonezero-booking.json in the xAI collection (use --booking-json)" >&2
      exit 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$RESTAURANT" ]; then
        echo "error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      RESTAURANT="$1"
      shift
      ;;
  esac
done

if [ -z "$RESTAURANT" ]; then
  usage >&2
  exit 2
fi

require_number "restaurant" "$RESTAURANT"

require_env TELNYX_API_KEY
require_env PHONEZERO_FROM_NUMBER
require_env PHONEZERO_TEXML_APP_ID

require_number "PHONEZERO_FROM_NUMBER" "$PHONEZERO_FROM_NUMBER"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to build/parse JSON" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$BOOKING_JSON" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would upload booking JSON via put-booking-file.sh (skipped on --dry-run)"
  else
    "${SCRIPT_DIR}/put-booking-file.sh" "$BOOKING_JSON"
  fi
fi
export PHONEZERO_BRIDGE_XML="${SCRIPT_DIR}/../texml/bridge.xml"
export PHONEZERO_RESTAURANT="$RESTAURANT"
# SIP To is the xAI number the agent answers. Default: the Telnyx DID
# (byo_trunk). Override with PHONEZERO_XAI_SIP_NUMBER when the agent is
# on an xAI-provisioned number (e.g. a second team that cannot steal
# the DID still registered on another team).
PHONEZERO_SIP_NUMBER="${PHONEZERO_XAI_SIP_NUMBER:-$PHONEZERO_FROM_NUMBER}"
export PHONEZERO_TO="sip:${PHONEZERO_SIP_NUMBER}@sip.voice.x.ai;transport=tls"
PHONEZERO_TEXML="$(build_texml)"
export PHONEZERO_TEXML

resolve_account_sid
PAYLOAD="$(build_payload)"
# account_sid path param (URL-encoded):
# https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
ACCOUNT_SID_ENC="$(urlencode "$TELNYX_ACCOUNT_SID")"
URL="https://api.telnyx.com/v2/texml/Accounts/${ACCOUNT_SID_ENC}/Calls"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "POST ${URL}"
  echo "Authorization: Bearer <redacted>"
  echo "Content-Type: application/json"
  echo "${PAYLOAD}"
  exit 0
fi

# -sS: no progress meter, still report curl errors. Do not use -v (leaks the
# Authorization header). HTTP status is appended on the last line.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

HTTP_CODE="$(
  curl -sSg \
    -o "$TMP" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${TELNYX_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary "$PAYLOAD" \
    "$URL"
)"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "error: initiate-call HTTP ${HTTP_CODE}" >&2
  echo "(response body excerpt; Texml redacted; first 400 chars:)" >&2
  python3 -c '
import json, sys
body = sys.stdin.read()
try:
    data = json.loads(body)
    def redact(obj):
        if isinstance(obj, dict):
            out = {}
            for key, val in obj.items():
                if str(key).lower() == "texml":
                    out[key] = "<redacted>"
                else:
                    out[key] = redact(val)
            return out
        if isinstance(obj, list):
            return [redact(x) for x in obj]
        return obj
    body = json.dumps(redact(data), separators=(",", ":"))
except Exception:
    pass
print(body[:400])
' <"$TMP" >&2
  exit 1
fi

CALL_SID="$(extract_call_sid <"$TMP")"
echo "$CALL_SID"

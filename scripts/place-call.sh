#!/usr/bin/env bash
# Developer tool for a personal machine that is allowed to hold API keys. The
# Grok Bot production path uses the Telnyx hosted MCP and never exports
# TELNYX_API_KEY into its environment.
#
# place-call.sh — curl equivalent of the Telnyx hosted MCP dial.
#
# Production path is the Telnyx hosted MCP. This script POSTs the same
# TeXML REST initiate-call request for local testing.
#
# Endpoint (verified):
#   POST https://api.telnyx.com/v2/texml/Accounts/{account_sid}/Calls
#   https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
#
# TeXML REST uses CamelCase JSON keys (To / From / Url / MachineDetection).
# ApplicationSid is required by the OpenAPI schema even when Url is set.
#
# AMD: restaurant-leg MachineDetection belongs on THIS request, not on
# <Dial><Sip> in the TeXML bin (that would classify the xAI agent).
# https://developers.telnyx.com/docs/voice/programmable-voice/texml-answering-machine
#
# StatusCallback is omitted (zero-server).
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   PHONEZERO_FROM_NUMBER
#   PHONEZERO_TEXML_BIN_URL
#   PHONEZERO_TEXML_APP_ID
# Optional / auto-resolved:
#   TELNYX_ACCOUNT_SID — if unset, GET /v2/whoami → data.organization_id
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: place-call.sh [--dry-run] E.164_NUMBER

Place a TeXML outbound call to a US E.164 number and print the Call SID.
To and PHONEZERO_FROM_NUMBER must match +1 and 10 digits (v1 is US-only).

  --dry-run   Print the request (API key redacted) without sending it.

Required environment:
  TELNYX_API_KEY
  PHONEZERO_FROM_NUMBER              E.164 caller ID on the Telnyx account
  PHONEZERO_TEXML_BIN_URL            public TeXML Bin URL (static XML)
  PHONEZERO_TEXML_APP_ID             TeXML Application id (ApplicationSid)

Optional / auto-resolved:
  TELNYX_ACCOUNT_SID                 if unset, GET /v2/whoami → data.organization_id

Example (fixture number only):
  place-call.sh +15555550100
  place-call.sh --dry-run +15555550100
EOF
}

# US E.164 only (v1 ships US-only). +1 and exactly 10 more digits.
is_us_e164() {
  [[ "$1" =~ ^\+1[0-9]{10}$ ]]
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
    curl -sS \
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

# Build the CamelCase JSON body. python3 avoids interpolation bugs in URLs.
# Field names verified against InitiateCallRequest:
# https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
build_payload() {
  python3 -c '
import json, os
print(json.dumps({
    "To": os.environ["PHONEZERO_TO"],
    "From": os.environ["PHONEZERO_FROM_NUMBER"],
    "Url": os.environ["PHONEZERO_TEXML_BIN_URL"],
    # UrlMethod GET: TeXML Bins are static files; Mission Control setup
    # uses GET to read the bin.
    # https://developers.telnyx.com/docs/voice/programmable-voice/texml-setup
    "UrlMethod": "GET",
    # ApplicationSid is required by InitiateCallRequest.
    # https://developers.telnyx.com/api-reference/texml-rest-commands/initiate-an-outbound-call
    "ApplicationSid": os.environ["PHONEZERO_TEXML_APP_ID"],
    # Restaurant-leg AMD. Enable = classify as soon as machine is identified
    # (human | machine_start | fax | unknown on the AMD callback).
    # https://developers.telnyx.com/docs/voice/programmable-voice/texml-answering-machine
    "MachineDetection": "Enable",
    "DetectionMode": "Premium",
    # AsyncAmd MUST be true. Sync AMD (default false) blocks TeXML until a
    # StatusCallback can return new instructions — PhoneZero has no server,
    # so sync would stall the SIP bridge. AsyncAmdStatusCallback is omitted
    # (zero-server). The AMD verdict lands on answered_by of the call-fetch
    # endpoint (GET /v2/texml/Accounts/{account_sid}/Calls/{call_sid};
    # enum: human | machine | not_sure), not on a webhook.
    # https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-a-call
    "AsyncAmd": True,
    # Seconds to wait for the restaurant to answer. Range 5–120.
    # SKILL.md is canonical: Timeout is 30.
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
TO=""

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
      if [ -n "$TO" ]; then
        echo "error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      TO="$1"
      shift
      ;;
  esac
done

if [ -z "$TO" ]; then
  usage >&2
  exit 2
fi

if ! is_us_e164 "$TO"; then
  echo "error: destination must be a US E.164 number (+1 and 10 digits, e.g. +15555550100)" >&2
  exit 2
fi

require_env TELNYX_API_KEY
require_env PHONEZERO_FROM_NUMBER
require_env PHONEZERO_TEXML_BIN_URL
require_env PHONEZERO_TEXML_APP_ID

if ! is_us_e164 "$PHONEZERO_FROM_NUMBER"; then
  echo "error: PHONEZERO_FROM_NUMBER must be a US E.164 number (+1 and 10 digits, e.g. +15555550100)" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to build/parse JSON" >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

export PHONEZERO_TO="$TO"
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
  curl -sS \
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
  echo "(response body omitted if it might echo request fields; first 400 chars:)" >&2
  python3 -c '
import sys
body = sys.stdin.read()
print(body[:400])
' <"$TMP" >&2
  exit 1
fi

CALL_SID="$(extract_call_sid <"$TMP")"
echo "$CALL_SID"

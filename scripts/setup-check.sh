#!/usr/bin/env bash
# Developer tool for a personal machine that is allowed to hold API keys. The
# Grok Bot production path uses the Telnyx hosted MCP and never exports
# TELNYX_API_KEY into its environment.
#
# setup-check.sh — preflight the PhoneZero Telnyx (and optional xAI) invariants.
#
# This script verifies exactly:
#   - TELNYX_API_KEY authenticates (GET /v2/balance)
#   - account SID resolvable via whoami (TELNYX_ACCOUNT_SID or GET /v2/whoami)
#   - PHONEZERO_FROM_NUMBER exists on the account
#   - the TeXML application exists and is active
#   - the DID is attached to that app (connection_id == PHONEZERO_TEXML_APP_ID)
#   - if XAI_API_KEY is set: GET /v2/phone-numbers shows the DID registered
#     with origin byo_trunk; missing agentId is a warning (Builder is console-only)
# It does NOT verify that the agent answers.
#
# Verified endpoints:
#   GET /v2/balance
#     https://developers.telnyx.com/api-reference/billing/get-user-balance-details
#   GET /v2/phone_numbers?filter[phone_number]=...
#     https://developers.telnyx.com/api-reference/phone-number-configurations/list-phone-numbers
#   GET /v2/texml_applications/{id}
#     https://developers.telnyx.com/api-reference/texml-applications/retrieve-a-texml-application
#   GET https://api.x.ai/v2/phone-numbers
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   PHONEZERO_FROM_NUMBER
#   PHONEZERO_TEXML_APP_ID
# Optional / auto-resolved:
#   TELNYX_ACCOUNT_SID — if unset, GET /v2/whoami → data.organization_id
#   PHONEZERO_XAI_SIP_NUMBER — defaults to PHONEZERO_FROM_NUMBER for the xAI check
#   XAI_API_KEY — if set, verify BYO registration
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-check.sh

Verify PhoneZero Telnyx configuration. Prints a checklist. Exits non-zero
if any check fails. Never prints API keys.

Verifies: auth works; account SID resolvable via whoami; FROM number on
account; TeXML app exists/active; DID connection_id matches the TeXML app.
If XAI_API_KEY is set: DID is registered with xAI (origin byo_trunk);
missing agentId is a warning, not a failure.

Does NOT verify that the agent answers.

Required environment:
  TELNYX_API_KEY
  PHONEZERO_FROM_NUMBER              E.164 DID on the account (e.g. +15555550100)
  PHONEZERO_TEXML_APP_ID             TeXML Application id

Optional:
  TELNYX_ACCOUNT_SID                 if unset, GET /v2/whoami → data.organization_id
  PHONEZERO_XAI_SIP_NUMBER           defaults to PHONEZERO_FROM_NUMBER
  XAI_API_KEY                        if set, verify xAI BYO registration
EOF
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "FAIL  ${name} is not set"
    return 1
  fi
  echo "PASS  ${name} is set"
  return 0
}

is_us_e164() {
  [[ "$1" =~ ^\+1[0-9]{10}$ ]]
}

# Authenticated GET. Body → $1, HTTP status → stdout.
telnyx_get() {
  local out_file="$1"
  local url="$2"
  curl -sSg \
    -o "$out_file" \
    -w '%{http_code}' \
    -H "Authorization: Bearer ${TELNYX_API_KEY}" \
    -H "Accept: application/json" \
    "$url"
}

FAILS=0
fail() {
  echo "FAIL  $1"
  FAILS=$((FAILS + 1))
}
pass() {
  echo "PASS  $1"
}

# organization_id from GET /v2/whoami is the TeXML Accounts/{account_sid} value.
resolve_account_sid() {
  if [ -n "${TELNYX_ACCOUNT_SID:-}" ]; then
    pass "TELNYX_ACCOUNT_SID is set"
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
  pass "account SID resolvable via whoami"
}

if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

echo "PhoneZero setup check"
echo "====================="
echo "Verifies: auth works; account SID resolvable via whoami; FROM number on"
echo "account; TeXML app exists/active; DID is attached to that app."
echo "If XAI_API_KEY is set: DID registered with xAI (origin byo_trunk)."
echo "Does NOT verify that the agent answers."
echo

if ! require_env TELNYX_API_KEY; then
  FAILS=$((FAILS + 1))
fi
if ! require_env PHONEZERO_FROM_NUMBER; then
  FAILS=$((FAILS + 1))
fi
if ! require_env PHONEZERO_TEXML_APP_ID; then
  FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -gt 0 ]; then
  echo
  echo "Result: ${FAILS} failure(s) — missing required environment."
  exit 1
fi

if [ -n "${PHONEZERO_XAI_SIP_NUMBER:-}" ]; then
  if ! is_us_e164 "$PHONEZERO_XAI_SIP_NUMBER"; then
    fail "PHONEZERO_XAI_SIP_NUMBER is not a US E.164 number (+1 and 10 digits, e.g. +15555550100)"
  else
    pass "PHONEZERO_XAI_SIP_NUMBER is US E.164"
  fi
else
  PHONEZERO_XAI_SIP_NUMBER="$PHONEZERO_FROM_NUMBER"
  export PHONEZERO_XAI_SIP_NUMBER
fi

resolve_account_sid

# Do not print the key. Only confirm it is non-empty (already) and works.
# US-only in v1 — must match the dialer's guard in place-call.sh (is_us_e164).
if ! is_us_e164 "$PHONEZERO_FROM_NUMBER"; then
  fail "PHONEZERO_FROM_NUMBER is not a US E.164 number (+1 and 10 digits, e.g. +15555550100)"
else
  pass "PHONEZERO_FROM_NUMBER is US E.164"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. API key authenticates via a cheap GET -------------------------
# GET /v2/balance — no path params, light billing read.
# https://developers.telnyx.com/api-reference/billing/get-user-balance-details
CODE="$(telnyx_get "${WORKDIR}/balance.json" "https://api.telnyx.com/v2/balance")"
if [ "$CODE" = "200" ]; then
  pass "TELNYX_API_KEY authenticates (GET /v2/balance HTTP 200)"
elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
  fail "TELNYX_API_KEY rejected (GET /v2/balance HTTP ${CODE})"
else
  fail "GET /v2/balance HTTP ${CODE} (expected 200)"
fi

# --- 2. From-number exists on the account and is attached to the app --
# filter[phone_number]: "Requires at least three digits. Non-numerical
# characters will result in no values being returned." The + is a
# non-numerical character, so strip it for the filter and match E.164
# exactly in the response.
# https://developers.telnyx.com/api-reference/phone-number-configurations/list-phone-numbers
DIGITS="${PHONEZERO_FROM_NUMBER#+}"
PN_CODE="$(
  curl -sSg \
    -o "${WORKDIR}/numbers.json" \
    -w '%{http_code}' \
    -G \
    --data-urlencode "filter[phone_number]=${DIGITS}" \
    --data-urlencode "filter[status]=active" \
    --data-urlencode "page[size]=10" \
    -H "Authorization: Bearer ${TELNYX_API_KEY}" \
    -H "Accept: application/json" \
    "https://api.telnyx.com/v2/phone_numbers"
)"
if [ "$PN_CODE" != "200" ]; then
  fail "list phone numbers HTTP ${PN_CODE}"
else
  PN_INFO="$(
    WANT="$PHONEZERO_FROM_NUMBER" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
want=os.environ["WANT"]
digits=want.lstrip("+")
for item in (d.get("data") or []):
    num=str(item.get("phone_number") or "")
    if num==want or num.lstrip("+")==digits:
        print("yes")
        print(item.get("id") or "")
        print(item.get("connection_id") or "")
        raise SystemExit(0)
print("no")
' <"${WORKDIR}/numbers.json"
  )"
  PN_MATCH="$(printf '%s\n' "$PN_INFO" | sed -n '1p')"
  PN_CONN="$(printf '%s\n' "$PN_INFO" | sed -n '3p')"
  if [ "$PN_MATCH" = "yes" ]; then
    pass "PHONEZERO_FROM_NUMBER exists on the account"
    if [ "$PN_CONN" = "$PHONEZERO_TEXML_APP_ID" ]; then
      pass "DID connection_id matches PHONEZERO_TEXML_APP_ID"
    else
      fail "DID is not attached to PHONEZERO_TEXML_APP_ID (connection_id=${PN_CONN:-empty})"
    fi
  else
    fail "PHONEZERO_FROM_NUMBER not found among account phone numbers"
  fi
fi

# --- 3. TeXML application exists --------------------------------------
# https://developers.telnyx.com/api-reference/texml-applications/retrieve-a-texml-application
APP_ID_ENC="$(
  APP_ID="$PHONEZERO_TEXML_APP_ID" python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["APP_ID"], safe=""))'
)"
APP_CODE="$(telnyx_get "${WORKDIR}/app.json" "https://api.telnyx.com/v2/texml_applications/${APP_ID_ENC}")"
if [ "$APP_CODE" = "200" ]; then
  APP_OK="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
data=d.get("data") or {}
rid=data.get("record_type") or ""
active=data.get("active")
print("ok" if rid=="texml_application" else "bad-type")
print("active" if active else "inactive")
print(data.get("friendly_name") or "")
print(data.get("voice_url") or "")
print(data.get("voice_method") or "")
' <"${WORKDIR}/app.json"
  )"
  APP_TYPE="$(printf '%s\n' "$APP_OK" | sed -n '1p')"
  APP_ACTIVE="$(printf '%s\n' "$APP_OK" | sed -n '2p')"
  APP_NAME="$(printf '%s\n' "$APP_OK" | sed -n '3p')"
  APP_VOICE_URL="$(printf '%s\n' "$APP_OK" | sed -n '4p')"
  APP_VOICE_METHOD="$(printf '%s\n' "$APP_OK" | sed -n '5p')"
  if [ "$APP_TYPE" = "ok" ]; then
    pass "TeXML application exists (id set; friendly_name=${APP_NAME:-unset})"
  else
    fail "GET /v2/texml_applications/{id} did not return record_type=texml_application"
  fi
  if [ "$APP_ACTIVE" = "active" ]; then
    pass "TeXML application is active"
  else
    fail "TeXML application is not active"
  fi
  # voice_url is fetched only for INBOUND calls (texml/inbound.xml).
  if [ "$APP_VOICE_METHOD" = "get" ] || [ "$APP_VOICE_METHOD" = "GET" ]; then
    pass "TeXML application voice_method is GET (inbound.xml)"
  else
    echo "WARN  TeXML application voice_method=${APP_VOICE_METHOD:-unset} (inbound.xml is served GET)"
  fi
  if [ -n "$APP_VOICE_URL" ]; then
    echo "INFO  application voice_url=${APP_VOICE_URL} (inbound only; outbound calls carry inline Texml)"
  fi
elif [ "$APP_CODE" = "404" ]; then
  fail "TeXML application not found (GET /v2/texml_applications/{id} HTTP 404)"
else
  fail "GET /v2/texml_applications/{id} HTTP ${APP_CODE}"
fi

# --- 4. xAI BYO registration (optional) -------------------------------
# GET https://api.x.ai/v2/phone-numbers
# Agent creation is console-only; missing agentId is a warning, not a fail.
if [ -z "${XAI_API_KEY:-}" ]; then
  echo "INFO  XAI_API_KEY unset — skipping xAI phone-number registration check"
else
  XAI_CODE="$(
    curl -sSg \
      -o "${WORKDIR}/xai-numbers.json" \
      -w '%{http_code}' \
      -H "Authorization: Bearer ${XAI_API_KEY}" \
      -H "Accept: application/json" \
      "https://api.x.ai/v2/phone-numbers"
  )" || true
  if [ "$XAI_CODE" != "200" ]; then
    fail "GET https://api.x.ai/v2/phone-numbers HTTP ${XAI_CODE}"
  else
    XAI_INFO="$(
      WANT="$PHONEZERO_XAI_SIP_NUMBER" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
want=os.environ["WANT"]
digits=want.lstrip("+")
items=d.get("phoneNumbers") or d.get("phone_numbers") or []
for item in items:
    num=str(item.get("phoneNumber") or item.get("phone_number") or "")
    if num==want or num.lstrip("+")==digits:
        print("yes")
        print(item.get("origin") or "")
        print(item.get("agentId") or item.get("agent_id") or "")
        raise SystemExit(0)
print("no")
' <"${WORKDIR}/xai-numbers.json"
    )"
    XAI_MATCH="$(printf '%s\n' "$XAI_INFO" | sed -n '1p')"
    XAI_ORIGIN="$(printf '%s\n' "$XAI_INFO" | sed -n '2p')"
    XAI_AGENT="$(printf '%s\n' "$XAI_INFO" | sed -n '3p')"
    if [ "$XAI_MATCH" != "yes" ]; then
      fail "PHONEZERO_XAI_SIP_NUMBER not registered with xAI (GET /v2/phone-numbers)"
    else
      if [ "$XAI_ORIGIN" = "byo_trunk" ]; then
        pass "DID is registered with xAI (origin=byo_trunk)"
      else
        fail "xAI registration origin is ${XAI_ORIGIN:-empty}, expected byo_trunk"
      fi
      if [ -n "$XAI_AGENT" ]; then
        pass "xAI agentId is attached"
      else
        echo "WARN  no xAI agentId attached — create the agent in Voice Agent Builder (console-only), then PATCH /v2/phone-numbers/{id} with fieldMask agent_id"
      fi
    fi
  fi
fi

echo
echo "Scope: auth works; account SID resolvable via whoami; FROM number on"
echo "account; TeXML app exists/active; DID attached to that app."
echo "Not verified: agent answers."
if [ "$FAILS" -gt 0 ]; then
  echo "Result: ${FAILS} failure(s)"
  exit 1
fi
echo "Result: all checks passed"
exit 0

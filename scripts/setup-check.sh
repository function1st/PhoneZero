#!/usr/bin/env bash
# setup-check.sh — preflight the PhoneZero Telnyx configuration invariants.
#
# Checks (exit non-zero on any failure; never echo secrets):
#   1. TELNYX_API_KEY authenticates (cheap GET /v2/balance)
#   2. PHONEZERO_FROM_NUMBER exists on the account
#   3. The TeXML application exists
#   4. The TeXML bin URL fetches and contains <Dial> and sip.voice.x.ai
#
# Verified endpoints:
#   GET /v2/balance
#     https://developers.telnyx.com/api-reference/billing/get-user-balance-details
#   GET /v2/phone_numbers?filter[phone_number]=...
#     https://developers.telnyx.com/api-reference/phone-number-configurations/list-phone-numbers
#   GET /v2/texml_applications/{id}
#     https://developers.telnyx.com/api-reference/texml-applications/retrieve-a-texml-application
#   GET /v2/texml_applications  (fallback list)
#     https://developers.telnyx.com/api-reference/texml-applications/list-all-texml-applications
#   TeXML Bin URL (public GET of static XML)
#     https://developers.telnyx.com/docs/voice/programmable-voice/texml-setup
#     https://developers.telnyx.com/docs/voice/programmable-voice/texml-bin-quickstart
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   PHONEZERO_FROM_NUMBER
#   PHONEZERO_TEXML_APP_ID
#   PHONEZERO_TEXML_BIN_URL
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-check.sh

Verify PhoneZero Telnyx configuration. Prints a checklist. Exits non-zero
if any check fails. Never prints TELNYX_API_KEY.

Required environment:
  TELNYX_API_KEY
  PHONEZERO_FROM_NUMBER              E.164 DID on the account (e.g. +15555550100)
  PHONEZERO_TEXML_APP_ID             TeXML Application id
  PHONEZERO_TEXML_BIN_URL            public TeXML Bin URL
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

# Authenticated GET. Body → $1, HTTP status → stdout.
telnyx_get() {
  local out_file="$1"
  local url="$2"
  curl -sS \
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

if ! require_env TELNYX_API_KEY; then
  FAILS=$((FAILS + 1))
fi
if ! require_env PHONEZERO_FROM_NUMBER; then
  FAILS=$((FAILS + 1))
fi
if ! require_env PHONEZERO_TEXML_APP_ID; then
  FAILS=$((FAILS + 1))
fi
if ! require_env PHONEZERO_TEXML_BIN_URL; then
  FAILS=$((FAILS + 1))
fi

if [ "$FAILS" -gt 0 ]; then
  echo
  echo "Result: ${FAILS} failure(s) — missing required environment."
  exit 1
fi

# Do not print the key. Only confirm it is non-empty (already) and works.
if [[ ! "${PHONEZERO_FROM_NUMBER}" =~ ^\+[1-9][0-9]{7,14}$ ]]; then
  fail "PHONEZERO_FROM_NUMBER is not E.164 (e.g. +15555550100)"
else
  pass "PHONEZERO_FROM_NUMBER looks like E.164"
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

# --- 2. From-number exists on the account -----------------------------
# filter[phone_number]: "Requires at least three digits. Non-numerical
# characters will result in no values being returned." The + is a
# non-numerical character, so strip it for the filter and match E.164
# exactly in the response.
# https://developers.telnyx.com/api-reference/phone-number-configurations/list-phone-numbers
DIGITS="${PHONEZERO_FROM_NUMBER#+}"
# curl --get --data-urlencode builds filter[phone_number]=...
PN_CODE="$(
  curl -sS \
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
  MATCH="$(
    WANT="$PHONEZERO_FROM_NUMBER" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
want=os.environ["WANT"]
digits=want.lstrip("+")
found=False
for item in (d.get("data") or []):
    num=str(item.get("phone_number") or "")
    if num==want or num.lstrip("+")==digits:
        found=True
        break
print("yes" if found else "no")
' <"${WORKDIR}/numbers.json"
  )"
  if [ "$MATCH" = "yes" ]; then
    pass "PHONEZERO_FROM_NUMBER exists on the account"
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
  # voice_method get is what TeXML Bin setup recommends for static XML.
  # https://developers.telnyx.com/docs/voice/programmable-voice/texml-setup
  if [ "$APP_VOICE_METHOD" = "get" ] || [ "$APP_VOICE_METHOD" = "GET" ]; then
    pass "TeXML application voice_method is GET (static bin)"
  else
    # Not fatal: place-call.sh sends UrlMethod=GET per-call.
    echo "WARN  TeXML application voice_method=${APP_VOICE_METHOD:-unset} (bin setup docs use GET)"
  fi
  if [ -n "$APP_VOICE_URL" ]; then
    echo "INFO  application voice_url is set (per-call Url may override it)"
  fi
elif [ "$APP_CODE" = "404" ]; then
  fail "TeXML application not found (GET /v2/texml_applications/{id} HTTP 404)"
else
  fail "GET /v2/texml_applications/{id} HTTP ${APP_CODE}"
fi

# --- 4. TeXML bin URL fetches and looks like the PhoneZero bridge -----
# Bins are public static XML (no API key). Do not send the Telnyx bearer
# to a third-party URL.
case "$PHONEZERO_TEXML_BIN_URL" in
  https://*)
    pass "PHONEZERO_TEXML_BIN_URL is https"
    ;;
  *)
    fail "PHONEZERO_TEXML_BIN_URL must be an https URL"
    ;;
esac

BIN_CODE="$(
  curl -sS \
    -o "${WORKDIR}/bin.xml" \
    -w '%{http_code}' \
    -L \
    --max-time 20 \
    "$PHONEZERO_TEXML_BIN_URL"
)"
if [ "$BIN_CODE" != "200" ]; then
  fail "TeXML bin URL HTTP ${BIN_CODE}"
else
  pass "TeXML bin URL fetches (HTTP 200)"
  if grep -q '<Dial' "${WORKDIR}/bin.xml"; then
    pass "TeXML bin contains <Dial>"
  else
    fail "TeXML bin does not contain <Dial>"
  fi
  if grep -q 'sip.voice.x.ai' "${WORKDIR}/bin.xml"; then
    pass "TeXML bin contains sip.voice.x.ai"
  else
    fail "TeXML bin does not contain sip.voice.x.ai"
  fi
  if grep -q '{PHONEZERO_XAI_SIP_NUMBER}' "${WORKDIR}/bin.xml"; then
    fail "TeXML bin still contains unsubstituted {PHONEZERO_XAI_SIP_NUMBER} (bins are static; substitute at setup)"
  else
    pass "TeXML bin placeholder {PHONEZERO_XAI_SIP_NUMBER} has been substituted"
  fi
  if grep -q '<Sip' "${WORKDIR}/bin.xml"; then
    pass "TeXML bin contains <Sip>"
  else
    fail "TeXML bin does not contain <Sip>"
  fi
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "Result: ${FAILS} failure(s)"
  exit 1
fi
echo "Result: all checks passed"
exit 0

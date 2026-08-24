#!/usr/bin/env bash
# Developer tool for a personal machine that is allowed to hold API keys. The
# Grok Bot production path uses the Telnyx hosted MCP and never exports
# TELNYX_API_KEY into its environment.
#
# provision.sh — one-time PhoneZero provisioning (idempotent: check-before-create).
#
# Telnyx (verified):
#   GET  /v2/whoami
#     → data.organization_id is the TeXML account_sid
#   POST /v2/outbound_voice_profiles
#     accepted combo: traffic_type=conversational, service_plan=global,
#     usage_payment_method=rate-deck (error 10015 otherwise)
#   POST /v2/texml_applications
#     voice_url is fetched only for INBOUND calls to the DID
#   PATCH /v2/phone_numbers/{phone_number_id}
#     {"connection_id":"<texml_app_id>"}
#
# xAI (verified; skipped unless XAI_API_KEY is set):
#   GET    https://api.x.ai/v2/phone-numbers
#   POST   https://api.x.ai/v2/phone-numbers
#     {"name":"PhoneZero","phoneNumber":"+1…","origin":"byo_trunk"}
#   PATCH  https://api.x.ai/v2/phone-numbers/{phoneNumberId}
#     {"phoneNumber":{"agentId":"agent_…"},"fieldMask":{"paths":["agent_id"]}}
# Voice Agent Builder agent *creation* remains console-only.
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   PHONEZERO_FROM_NUMBER
set -euo pipefail

DEFAULT_INBOUND_XML_URL="https://raw.githubusercontent.com/function1st/PhoneZero/main/texml/inbound.xml"
PROFILE_NAME="PhoneZero US-only"
APP_NAME="PhoneZero"

usage() {
  cat <<'EOF'
Usage: provision.sh [--dry-run]

One-time PhoneZero provisioning. Idempotent: find-or-create each resource.
Prints the ids to copy into plugin variables. Never prints API keys.

  --dry-run   Inspect existing resources; print intended creates/updates
              without sending POST/PATCH.

Required environment:
  TELNYX_API_KEY
  PHONEZERO_FROM_NUMBER              US E.164 DID already on the account

Optional:
  TELNYX_ACCOUNT_SID                 if unset, GET /v2/whoami → data.organization_id
  PHONEZERO_XAI_SIP_NUMBER           defaults to PHONEZERO_FROM_NUMBER
  PHONEZERO_INBOUND_XML_URL          TeXML app voice_url (inbound reject page)
  XAI_API_KEY                        if set, register the DID with xAI (byo_trunk)
  PHONEZERO_XAI_AGENT_ID             if set (requires XAI_API_KEY), attach this
                                     Builder agent via fieldMask PATCH

Example (fixture number only):
  PHONEZERO_FROM_NUMBER=+15555550100 provision.sh --dry-run
EOF
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "error: $name is not set" >&2
    exit 2
  fi
}

is_us_e164() {
  [[ "$1" =~ ^\+1[0-9]{10}$ ]]
}

urlencode() {
  VAL="$1" python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["VAL"], safe=""))'
}

# Authenticated Telnyx GET/POST/PATCH. Body file optional (3rd arg).
# Writes response to $out; prints HTTP status on stdout.
telnyx_http() {
  local method="$1"
  local url="$2"
  local out="$3"
  local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sSg \
      -o "$out" \
      -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${TELNYX_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data-binary @"$body" \
      "$url"
  else
    curl -sSg \
      -o "$out" \
      -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${TELNYX_API_KEY}" \
      -H "Accept: application/json" \
      "$url"
  fi
}

xai_http() {
  local method="$1"
  local url="$2"
  local out="$3"
  local body="${4:-}"
  if [ -n "$body" ]; then
    curl -sSg \
      -o "$out" \
      -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${XAI_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data-binary @"$body" \
      "$url"
  else
    curl -sSg \
      -o "$out" \
      -w '%{http_code}' \
      -X "$method" \
      -H "Authorization: Bearer ${XAI_API_KEY}" \
      -H "Accept: application/json" \
      "$url"
  fi
}

# First data[].id whose <field> equals WANT. Empty if none.
json_find_data_id() {
  FIELD="$1" WANT="$2" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
field=os.environ["FIELD"]
want=os.environ["WANT"]
for item in (d.get("data") or []):
    if str(item.get(field) or "") == want:
        rid=item.get("id") or ""
        if rid:
            print(rid)
            raise SystemExit(0)
'
}

json_data_id() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
data=d.get("data") if isinstance(d, dict) else None
if isinstance(data, dict):
    rid=data.get("id") or ""
    if rid:
        print(rid)
        raise SystemExit(0)
rid=d.get("id") if isinstance(d, dict) else ""
if rid:
    print(rid)
    raise SystemExit(0)
raise SystemExit(1)
'
}

# organization_id from GET /v2/whoami is the TeXML Accounts/{account_sid} value.
resolve_account_sid() {
  if [ -n "${TELNYX_ACCOUNT_SID:-}" ]; then
    return 0
  fi
  local tmp code org
  tmp="$(mktemp)"
  code="$(telnyx_http GET "https://api.telnyx.com/v2/whoami" "$tmp")" || true
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

DRY_RUN=0

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
      echo "error: unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

require_env TELNYX_API_KEY
require_env PHONEZERO_FROM_NUMBER

if ! is_us_e164 "$PHONEZERO_FROM_NUMBER"; then
  echo "error: PHONEZERO_FROM_NUMBER must be a US E.164 number (+1 and 10 digits, e.g. +15555550100)" >&2
  exit 2
fi

if [ -z "${PHONEZERO_XAI_SIP_NUMBER:-}" ]; then
  PHONEZERO_XAI_SIP_NUMBER="$PHONEZERO_FROM_NUMBER"
  export PHONEZERO_XAI_SIP_NUMBER
fi
if ! is_us_e164 "$PHONEZERO_XAI_SIP_NUMBER"; then
  echo "error: PHONEZERO_XAI_SIP_NUMBER must be a US E.164 number (+1 and 10 digits, e.g. +15555550100)" >&2
  exit 2
fi

if [ -z "${PHONEZERO_INBOUND_XML_URL:-}" ]; then
  PHONEZERO_INBOUND_XML_URL="$DEFAULT_INBOUND_XML_URL"
fi
export PROFILE_NAME APP_NAME
export PHONEZERO_INBOUND_XML_URL
export PHONEZERO_FROM_NUMBER
export PHONEZERO_XAI_SIP_NUMBER
if [ -n "${PHONEZERO_XAI_AGENT_ID:-}" ]; then
  export PHONEZERO_XAI_AGENT_ID
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "PhoneZero provision"
echo "==================="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "mode: dry-run (no POST/PATCH)"
fi
echo

resolve_account_sid

# --- Outbound voice profile -------------------------------------------
# GET /v2/outbound_voice_profiles
# POST /v2/outbound_voice_profiles
# https://developers.telnyx.com/api-reference/outbound-voice-profiles
PROFILE_ID=""
CODE="$(telnyx_http GET "https://api.telnyx.com/v2/outbound_voice_profiles?page[size]=250" "${WORKDIR}/profiles.json")" || true
if [ "$CODE" != "200" ]; then
  echo "error: GET /v2/outbound_voice_profiles HTTP ${CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/profiles.json" >&2
  exit 1
fi
PROFILE_ID="$(json_find_data_id name "$PROFILE_NAME" <"${WORKDIR}/profiles.json" || true)"
if [ -n "$PROFILE_ID" ]; then
  echo "found outbound voice profile ${PROFILE_NAME} (${PROFILE_ID})"
else
  python3 -c '
import json,os
print(json.dumps({
    "name": os.environ["PROFILE_NAME"],
    "traffic_type": "conversational",
    "service_plan": "global",
    "usage_payment_method": "rate-deck",
    "whitelisted_destinations": ["US"],
    "daily_spend_limit": "5.00",
    "daily_spend_limit_enabled": True,
}))
' >"${WORKDIR}/profile.body"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would POST /v2/outbound_voice_profiles"
    python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/profile.body"
  else
    CODE="$(telnyx_http POST "https://api.telnyx.com/v2/outbound_voice_profiles" "${WORKDIR}/profile.json" "${WORKDIR}/profile.body")" || true
    if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
      echo "error: POST /v2/outbound_voice_profiles HTTP ${CODE}" >&2
      python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/profile.json" >&2
      exit 1
    fi
    PROFILE_ID="$(json_data_id <"${WORKDIR}/profile.json")"
    echo "created outbound voice profile ${PROFILE_NAME} (${PROFILE_ID})"
  fi
fi
export PROFILE_ID

# --- TeXML application ------------------------------------------------
# GET /v2/texml_applications
# POST /v2/texml_applications
# PATCH /v2/texml_applications/{id}
# https://developers.telnyx.com/api-reference/texml-applications
APP_ID=""
CODE="$(telnyx_http GET "https://api.telnyx.com/v2/texml_applications?page[size]=250" "${WORKDIR}/apps.json")" || true
if [ "$CODE" != "200" ]; then
  echo "error: GET /v2/texml_applications HTTP ${CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/apps.json" >&2
  exit 1
fi
APP_ID="$(json_find_data_id friendly_name "$APP_NAME" <"${WORKDIR}/apps.json" || true)"

PROFILE_ID="${PROFILE_ID:-}"
python3 -c '
import json,os
print(json.dumps({
    "friendly_name": os.environ["APP_NAME"],
    "voice_url": os.environ["PHONEZERO_INBOUND_XML_URL"],
    "voice_method": "get",
    "outbound": {"outbound_voice_profile_id": os.environ.get("PROFILE_ID") or ""},
}))
' >"${WORKDIR}/app.body"

if [ -n "$APP_ID" ]; then
  echo "found TeXML application ${APP_NAME} (${APP_ID})"
  if [ -z "$PROFILE_ID" ] && [ "$DRY_RUN" -eq 1 ]; then
    echo "would PATCH /v2/texml_applications/{id} after profile create"
  elif [ -n "$PROFILE_ID" ]; then
    NEED_PATCH="$(
      WANT_URL="$PHONEZERO_INBOUND_XML_URL" WANT_PROFILE="$PROFILE_ID" WANT_NAME="$APP_NAME" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
want_url=os.environ["WANT_URL"]
want_profile=os.environ["WANT_PROFILE"]
want_name=os.environ["WANT_NAME"]
for item in (d.get("data") or []):
    if str(item.get("friendly_name") or "") != want_name:
        continue
    outbound=item.get("outbound") or {}
    url=str(item.get("voice_url") or "")
    method=str(item.get("voice_method") or "").lower()
    prof=str(outbound.get("outbound_voice_profile_id") or "")
    if url != want_url or method != "get" or prof != want_profile:
        print("yes")
    else:
        print("no")
    raise SystemExit(0)
print("yes")
' <"${WORKDIR}/apps.json"
    )"
    if [ "$NEED_PATCH" = "yes" ]; then
      APP_ENC="$(urlencode "$APP_ID")"
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "would PATCH /v2/texml_applications/${APP_ID}"
        python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/app.body"
      else
        CODE="$(telnyx_http PATCH "https://api.telnyx.com/v2/texml_applications/${APP_ENC}" "${WORKDIR}/app-patch.json" "${WORKDIR}/app.body")" || true
        if [ "$CODE" != "200" ]; then
          echo "error: PATCH /v2/texml_applications/{id} HTTP ${CODE}" >&2
          python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/app-patch.json" >&2
          exit 1
        fi
        echo "updated TeXML application ${APP_NAME} voice_url / outbound profile"
      fi
    fi
  fi
else
  if [ -z "$PROFILE_ID" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would POST /v2/texml_applications (after profile create)"
      python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/app.body"
    else
      echo "error: cannot create TeXML application without an outbound voice profile id" >&2
      exit 1
    fi
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "would POST /v2/texml_applications"
    python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/app.body"
  else
    CODE="$(telnyx_http POST "https://api.telnyx.com/v2/texml_applications" "${WORKDIR}/app.json" "${WORKDIR}/app.body")" || true
    if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
      echo "error: POST /v2/texml_applications HTTP ${CODE}" >&2
      python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/app.json" >&2
      exit 1
    fi
    APP_ID="$(json_data_id <"${WORKDIR}/app.json")"
    echo "created TeXML application ${APP_NAME} (${APP_ID})"
  fi
fi
export APP_ID

# --- Attach DID to the TeXML app --------------------------------------
# GET /v2/phone_numbers?filter[phone_number]=…
# PATCH /v2/phone_numbers/{phone_number_id}  {"connection_id":"<app id>"}
# https://developers.telnyx.com/api-reference/phone-number-configurations
DIGITS="${PHONEZERO_FROM_NUMBER#+}"
PN_CODE="$(
  curl -sSg \
    -o "${WORKDIR}/numbers.json" \
    -w '%{http_code}' \
    -G \
    --data-urlencode "filter[phone_number]=${DIGITS}" \
    --data-urlencode "page[size]=10" \
    -H "Authorization: Bearer ${TELNYX_API_KEY}" \
    -H "Accept: application/json" \
    "https://api.telnyx.com/v2/phone_numbers"
)" || true
if [ "$PN_CODE" != "200" ]; then
  echo "error: GET /v2/phone_numbers HTTP ${PN_CODE}" >&2
  python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/numbers.json" >&2
  exit 1
fi

PN_INFO="$(
  WANT="$PHONEZERO_FROM_NUMBER" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
want=os.environ["WANT"]
digits=want.lstrip("+")
for item in (d.get("data") or []):
    num=str(item.get("phone_number") or "")
    if num==want or num.lstrip("+")==digits:
        print(item.get("id") or "")
        print(item.get("connection_id") or "")
        raise SystemExit(0)
raise SystemExit(1)
' <"${WORKDIR}/numbers.json"
)" || {
  echo "error: PHONEZERO_FROM_NUMBER not found on the Telnyx account (buy the DID first)" >&2
  exit 1
}
PN_ID="$(printf '%s\n' "$PN_INFO" | sed -n '1p')"
PN_CONN="$(printf '%s\n' "$PN_INFO" | sed -n '2p')"
if [ -z "$PN_ID" ]; then
  echo "error: phone number record has no id" >&2
  exit 1
fi
echo "found DID ${PHONEZERO_FROM_NUMBER} (phone_number_id=${PN_ID})"

if [ -z "$APP_ID" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would PATCH /v2/phone_numbers/{id} connection_id=<new TeXML app>"
  else
    echo "error: no TeXML application id; cannot attach DID" >&2
    exit 1
  fi
elif [ "$PN_CONN" = "$APP_ID" ]; then
  echo "DID already attached to TeXML application ${APP_ID}"
else
  python3 -c '
import json,os
print(json.dumps({"connection_id": os.environ["APP_ID"]}))
' >"${WORKDIR}/did.body"
  PN_ENC="$(urlencode "$PN_ID")"
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would PATCH /v2/phone_numbers/${PN_ID} {\"connection_id\":\"${APP_ID}\"}"
  else
    CODE="$(telnyx_http PATCH "https://api.telnyx.com/v2/phone_numbers/${PN_ENC}" "${WORKDIR}/did.json" "${WORKDIR}/did.body")" || true
    if [ "$CODE" != "200" ]; then
      echo "error: PATCH /v2/phone_numbers/{id} HTTP ${CODE}" >&2
      python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/did.json" >&2
      exit 1
    fi
    echo "attached DID to TeXML application ${APP_ID}"
  fi
fi

# --- xAI phone-number registration (optional) -------------------------
# GET/POST/PATCH https://api.x.ai/v2/phone-numbers
XAI_PN_ID=""
XAI_AGENT_ATTACHED=""
XAI_ORIGIN=""
if [ -z "${XAI_API_KEY:-}" ]; then
  echo "XAI_API_KEY unset — skipping xAI phone-number registration"
else
  CODE="$(xai_http GET "https://api.x.ai/v2/phone-numbers" "${WORKDIR}/xai-numbers.json")" || true
  if [ "$CODE" != "200" ]; then
    echo "error: GET https://api.x.ai/v2/phone-numbers HTTP ${CODE}" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/xai-numbers.json" >&2
    exit 1
  fi
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
        print(item.get("phoneNumberId") or item.get("phone_number_id") or "")
        print(item.get("origin") or "")
        print(item.get("agentId") or item.get("agent_id") or "")
        raise SystemExit(0)
' <"${WORKDIR}/xai-numbers.json"
  )" || true
  if [ -n "$XAI_INFO" ]; then
    XAI_PN_ID="$(printf '%s\n' "$XAI_INFO" | sed -n '1p')"
    XAI_ORIGIN="$(printf '%s\n' "$XAI_INFO" | sed -n '2p')"
    XAI_AGENT_ATTACHED="$(printf '%s\n' "$XAI_INFO" | sed -n '3p')"
    echo "found xAI phone-number ${PHONEZERO_XAI_SIP_NUMBER} (phoneNumberId=${XAI_PN_ID} origin=${XAI_ORIGIN:-unset})"
    if [ "$XAI_ORIGIN" != "byo_trunk" ]; then
      echo "warning: xAI origin is ${XAI_ORIGIN:-empty}, expected byo_trunk" >&2
    fi
  else
    python3 -c '
import json,os
print(json.dumps({
    "name": "PhoneZero",
    "phoneNumber": os.environ["PHONEZERO_XAI_SIP_NUMBER"],
    "origin": "byo_trunk",
}))
' >"${WORKDIR}/xai-reg.body"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would POST https://api.x.ai/v2/phone-numbers"
      python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/xai-reg.body"
    else
      CODE="$(xai_http POST "https://api.x.ai/v2/phone-numbers" "${WORKDIR}/xai-reg.json" "${WORKDIR}/xai-reg.body")" || true
      if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
        echo "error: POST https://api.x.ai/v2/phone-numbers HTTP ${CODE}" >&2
        python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/xai-reg.json" >&2
        exit 1
      fi
      XAI_PN_ID="$(
        python3 -c '
import json,sys
d=json.load(sys.stdin)
item=d.get("phoneNumber") or d
if not isinstance(item, dict):
    item=d
rid=item.get("phoneNumberId") or item.get("phone_number_id") or d.get("phoneNumberId") or ""
if not rid and isinstance(d.get("phoneNumbers"), list) and d["phoneNumbers"]:
    rid=d["phoneNumbers"][0].get("phoneNumberId") or ""
if not rid:
    sys.exit(1)
print(rid)
' <"${WORKDIR}/xai-reg.json"
      )"
      XAI_ORIGIN="byo_trunk"
      echo "registered ${PHONEZERO_XAI_SIP_NUMBER} with xAI as byo_trunk (${XAI_PN_ID})"
    fi
  fi

  if [ -n "${PHONEZERO_XAI_AGENT_ID:-}" ]; then
    if [ "$XAI_AGENT_ATTACHED" = "$PHONEZERO_XAI_AGENT_ID" ]; then
      echo "xAI agent already attached (${PHONEZERO_XAI_AGENT_ID})"
    elif [ -z "$XAI_PN_ID" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "would PATCH https://api.x.ai/v2/phone-numbers/{id} agentId=${PHONEZERO_XAI_AGENT_ID}"
      else
        echo "error: no xAI phoneNumberId; cannot attach agent" >&2
        exit 1
      fi
    else
      python3 -c '
import json,os
print(json.dumps({
    "phoneNumber": {"agentId": os.environ["PHONEZERO_XAI_AGENT_ID"]},
    "fieldMask": {"paths": ["agent_id"]},
}))
' >"${WORKDIR}/xai-attach.body"
      XAI_ENC="$(urlencode "$XAI_PN_ID")"
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "would PATCH https://api.x.ai/v2/phone-numbers/${XAI_PN_ID}"
        python3 -c 'import sys; print(sys.stdin.read())' <"${WORKDIR}/xai-attach.body"
      else
        CODE="$(xai_http PATCH "https://api.x.ai/v2/phone-numbers/${XAI_ENC}" "${WORKDIR}/xai-attach.json" "${WORKDIR}/xai-attach.body")" || true
        if [ "$CODE" != "200" ]; then
          echo "error: PATCH https://api.x.ai/v2/phone-numbers/{id} HTTP ${CODE}" >&2
          echo "note: body must be {\"phoneNumber\":{\"agentId\":…},\"fieldMask\":{\"paths\":[\"agent_id\"]}} — a flat {\"agentId\":…} is rejected" >&2
          python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/xai-attach.json" >&2
          exit 1
        fi
        XAI_AGENT_ATTACHED="$PHONEZERO_XAI_AGENT_ID"
        echo "attached xAI agent ${PHONEZERO_XAI_AGENT_ID}"
      fi
    fi
  elif [ -z "$XAI_AGENT_ATTACHED" ]; then
    echo "no PHONEZERO_XAI_AGENT_ID — create the agent in Voice Agent Builder (console-only), then re-run with PHONEZERO_XAI_AGENT_ID set"
  fi
fi

echo
echo "Plugin variables (copy these)"
echo "-----------------------------"
echo "TELNYX_ACCOUNT_SID=${TELNYX_ACCOUNT_SID}"
echo "PHONEZERO_FROM_NUMBER=${PHONEZERO_FROM_NUMBER}"
echo "PHONEZERO_TEXML_APP_ID=${APP_ID:-<create the TeXML app, then re-run>}"
echo "PHONEZERO_XAI_SIP_NUMBER=${PHONEZERO_XAI_SIP_NUMBER}"
echo
echo "Other ids"
echo "---------"
echo "outbound_voice_profile_id=${PROFILE_ID:-<pending>}"
echo "telnyx_phone_number_id=${PN_ID}"
if [ -n "${XAI_API_KEY:-}" ]; then
  echo "xai_phone_number_id=${XAI_PN_ID:-<pending>}"
  echo "xai_origin=${XAI_ORIGIN:-<pending>}"
  echo "xai_agent_id=${XAI_AGENT_ATTACHED:-<not attached — Builder console, then PHONEZERO_XAI_AGENT_ID>}"
fi
echo
echo "Set PHONEZERO_AGENT_NAME and PHONEZERO_DISCLOSE_AI in Plugins → Configure."
echo "Enter TELNYX_API_KEY as a plugin variable (backend-held)."
echo "Enter XAI_API_KEY via Grok Bot's secure secret request flow."

#!/usr/bin/env bash
# Developer tool for a personal machine that may hold keys. Never echo keys.
#
# Upload phonezero-booking.json to xAI Files, attach it to the PhoneZero
# bookings collection, wait until DOCUMENT_STATUS_PROCESSED, print ids.
#
# Required env:
#   XAI_API_KEY
# Optional:
#   PHONEZERO_XAI_COLLECTION_ID — reuse this collection; otherwise find-or-create
#                                 name "PhoneZero bookings"
#
# Usage:
#   put-booking-file.sh PATH.json
#
# Prints:
#   COLLECTION_ID=...
#   FILE_ID=...
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: put-booking-file.sh PATH.json

Replace the collection document named phonezero-booking.json with PATH.json
(must be an object with kind "phonezero-booking"). Waits until the document
is processed. Prints COLLECTION_ID and FILE_ID. Never prints API keys.

Required environment:
  XAI_API_KEY
Optional:
  PHONEZERO_XAI_COLLECTION_ID
EOF
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "error: $name is not set" >&2
    exit 2
  fi
}

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  usage
  [ $# -eq 1 ] && exit 0
  exit 2
fi

JSON_PATH="$1"
if [ ! -f "$JSON_PATH" ]; then
  echo "error: not a file: ${JSON_PATH}" >&2
  exit 2
fi

require_env XAI_API_KEY

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

python3 -c '
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text(encoding="utf-8"))
if not isinstance(data, dict) or data.get("kind") != "phonezero-booking":
    sys.stderr.write("error: JSON must be an object with kind phonezero-booking\n")
    sys.exit(2)
required = ("spoken_name", "restaurant", "party", "date", "preferred_time", "window", "alternates", "booking_name", "callback")
missing = [k for k in required if k not in data or data[k] in (None, "")]
if missing:
    sys.stderr.write("error: booking JSON missing: " + ", ".join(missing) + "\n")
    sys.exit(2)
' "$JSON_PATH"

COLLECTION_NAME="PhoneZero bookings"
BOOKING_NAME="phonezero-booking.json"
API="https://api.x.ai/v1"

auth_api=(-H "Authorization: Bearer ${XAI_API_KEY}")

http_json() {
  # usage: http_json METHOD URL AUTH_ARRAY_NAME [curl extras...]
  # writes body to PHONEZERO_HTTP_BODY, sets PHONEZERO_HTTP_CODE
  local method="$1"
  local url="$2"
  shift 2
  local tmp
  tmp="$(mktemp)"
  PHONEZERO_HTTP_CODE="$(
    curl -sSg -o "$tmp" -w '%{http_code}' -X "$method" "$@" "$url"
  )" || true
  PHONEZERO_HTTP_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

resolve_collection_id() {
  if [ -n "${PHONEZERO_XAI_COLLECTION_ID:-}" ]; then
    printf '%s' "$PHONEZERO_XAI_COLLECTION_ID"
    return 0
  fi
  http_json GET "${API}/collections" "${auth_api[@]}" -H "Accept: application/json"
  if [ "$PHONEZERO_HTTP_CODE" != "200" ]; then
    echo "error: list collections HTTP ${PHONEZERO_HTTP_CODE}" >&2
    exit 1
  fi
  local found
  found="$(
    COLLECTION_NAME="$COLLECTION_NAME" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read())
name = os.environ["COLLECTION_NAME"]
items = data.get("collections") or data.get("data") or []
if isinstance(data, list):
    items = data
for c in items:
    if not isinstance(c, dict):
        continue
    if (c.get("collection_name") or c.get("name") or "") == name:
        cid = c.get("collection_id") or c.get("id") or ""
        if cid:
            print(cid)
            sys.exit(0)
' <<<"$PHONEZERO_HTTP_BODY"
  )"
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  http_json POST "${API}/collections" "${auth_api[@]}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary "$(python3 -c 'import json,os; print(json.dumps({
  "collection_name": os.environ["COLLECTION_NAME"],
  "collection_description": "Current PhoneZero reservation facts",
  "field_definitions": [{
    "key": "kind",
    "required": False,
    "inject_into_chunk": True,
    "unique": False,
    "description": "Document kind"
  }]
}))')"
  if [ "$PHONEZERO_HTTP_CODE" != "200" ] && [ "$PHONEZERO_HTTP_CODE" != "201" ]; then
    echo "error: create collection HTTP ${PHONEZERO_HTTP_CODE}" >&2
    exit 1
  fi
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
cid = d.get("collection_id") or d.get("id") or ""
if not cid:
    sys.exit(1)
print(cid)
' <<<"$PHONEZERO_HTTP_BODY" || {
    echo "error: create collection response missing collection_id" >&2
    exit 1
  }
}

remove_existing_booking() {
  local cid="$1"
  http_json GET "${API}/collections/${cid}/documents?name=${BOOKING_NAME}" "${auth_api[@]}" \
    -H "Accept: application/json"
  if [ "$PHONEZERO_HTTP_CODE" != "200" ]; then
    return 0
  fi
  local ids
  ids="$(
    BOOKING_NAME="$BOOKING_NAME" python3 -c '
import json, os, sys
data = json.loads(sys.stdin.read() or "{}")
want = os.environ["BOOKING_NAME"]
docs = data.get("documents") or data.get("data") or []
for d in docs:
    if not isinstance(d, dict):
        continue
    name = d.get("name") or d.get("filename") or ""
    fid = d.get("file_id") or d.get("id") or ""
    meta = d.get("file_metadata") or {}
    if isinstance(meta, dict):
        name = name or meta.get("name") or meta.get("filename") or ""
        fid = fid or meta.get("file_id") or meta.get("id") or ""
    if name == want and fid:
        print(fid)
' <<<"$PHONEZERO_HTTP_BODY"
  )"
  local fid
  for fid in $ids; do
    http_json DELETE "${API}/collections/${cid}/documents/${fid}" "${auth_api[@]}" \
      -H "Accept: application/json" || true
    http_json DELETE "${API}/files/${fid}" "${auth_api[@]}" \
      -H "Accept: application/json" || true
  done
}

upload_file() {
  local tmp
  tmp="$(mktemp)"
  PHONEZERO_HTTP_CODE="$(
    curl -sSg -o "$tmp" -w '%{http_code}' \
      -H "Authorization: Bearer ${XAI_API_KEY}" \
      -F expires_after=3600 \
      -F purpose=assistants \
      -F "file=@${JSON_PATH};filename=${BOOKING_NAME};type=application/json" \
      "${API}/files"
  )" || true
  PHONEZERO_HTTP_BODY="$(cat "$tmp")"
  rm -f "$tmp"
  if [ "$PHONEZERO_HTTP_CODE" != "200" ] && [ "$PHONEZERO_HTTP_CODE" != "201" ]; then
    echo "error: files upload HTTP ${PHONEZERO_HTTP_CODE}" >&2
    exit 1
  fi
  python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
fid = d.get("id") or ""
if not isinstance(fid, str) or not fid:
    sys.exit(1)
print(fid)
' <<<"$PHONEZERO_HTTP_BODY" || {
    echo "error: files upload missing id" >&2
    exit 1
  }
}

attach_and_wait() {
  local cid="$1"
  local fid="$2"
  http_json POST "${API}/collections/${cid}/documents/${fid}" "${auth_api[@]}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data-binary "$(CID="$cid" FID="$fid" python3 -c 'import json,os; print(json.dumps({"collection_id": os.environ["CID"], "file_id": os.environ["FID"], "fields": {"kind": "phonezero-booking"}}))')"
  if [ "$PHONEZERO_HTTP_CODE" != "200" ] && [ "$PHONEZERO_HTTP_CODE" != "201" ]; then
    echo "error: add document HTTP ${PHONEZERO_HTTP_CODE}" >&2
    exit 1
  fi
  local status
  for _ in $(seq 1 40); do
    http_json GET "${API}/collections/${cid}/documents/${fid}" "${auth_api[@]}" \
      -H "Accept: application/json"
    if [ "$PHONEZERO_HTTP_CODE" != "200" ]; then
      echo "error: get document HTTP ${PHONEZERO_HTTP_CODE}" >&2
      exit 1
    fi
    status="$(
      python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
print(d.get("status") if d.get("status") is not None else "")
' <<<"$PHONEZERO_HTTP_BODY"
    )"
    # REST may return the protobuf enum name or its int
    # (DOCUMENT_STATUS_UNKNOWN=0 … PROCESSED=2, FAILED=3).
    case "$status" in
      DOCUMENT_STATUS_PROCESSED|processed|PROCESSED|2)
        return 0
        ;;
      DOCUMENT_STATUS_FAILED|failed|FAILED|3)
        echo "error: document processing failed" >&2
        exit 1
        ;;
    esac
    sleep 3
  done
  echo "error: document not processed after 120s (last status=${status})" >&2
  exit 1
}

export COLLECTION_NAME
COLLECTION_ID="$(resolve_collection_id)"
remove_existing_booking "$COLLECTION_ID"
FILE_ID="$(upload_file)"
attach_and_wait "$COLLECTION_ID" "$FILE_ID"
printf 'COLLECTION_ID=%s\n' "$COLLECTION_ID"
printf 'FILE_ID=%s\n' "$FILE_ID"

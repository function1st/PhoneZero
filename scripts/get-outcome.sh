#!/usr/bin/env bash
# Developer tool for a personal machine that is allowed to hold API keys. The
# Grok Bot production path uses the Telnyx hosted MCP and never exports
# TELNYX_API_KEY into its environment.
#
# get-outcome.sh — poll a TeXML call to a terminal status, download a
# completed call-level dual-channel recording, and transcribe it with xAI STT.
#
# Call status (eventually consistent; MCP: retrieve_calls_accounts_texml_calls):
#   GET /v2/texml/Accounts/{account_sid}/Calls/{call_sid}
#   https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-a-call
#   AMD / answered_by are unused (MachineDetection is off). Voicemail is
#   classified from the transcript, not from answered_by.
#
# Recordings (MCP: recordings_json_calls_accounts_texml_recordings_json):
#   GET /v2/texml/Accounts/{account_sid}/Calls/{call_sid}/Recordings.json
#   https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-recordings-for-a-call
#   recordings[].media_url is an S3 presigned URL (expires ~600s). Download promptly.
#   Only status=completed with a non-empty media_url is downloaded.
#
# Default transcript: POST https://api.x.ai/v1/stt (multipart).
#   https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
#
# After successful STT, keep the Telnyx recording and a copy under recordings/
# (gitignored). Pass --delete-remote to DELETE it instead:
#   DELETE /v2/texml/Accounts/{account_sid}/Recordings/{recording_sid}.json
#   MCP: delete_recording_sid_json_recordings_accounts_texml_json (204)
#   https://developers.telnyx.com/api-reference/texml-rest-commands/delete-recording-resource
#
# Exit codes:
#   0  success (non-empty STT text)
#   1  failed (HTTP / download / empty STT)
#   2  config (missing env, missing XAI_API_KEY, bad args)
#   3  unknown (call or recording wait ended with no completed recording)
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   XAI_API_KEY   — required for STT (Grok Bot secure-secret flow)
# Optional / auto-resolved:
#   TELNYX_ACCOUNT_SID — if unset, GET /v2/whoami → data.organization_id
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: get-outcome.sh [--timeout SECONDS] [--interval SECONDS] [--rec-interval SECONDS] [--keep] [--keep-audio] [--keep-remote] [--delete-remote] [--no-keep-audio] CALL_SID

Poll a TeXML call until it reaches a terminal status, download a
completed recording (presigned media_url expires ~10 min), and
transcribe with xAI STT (multichannel). Prints the per-channel
transcript. Never prints media_url. Voicemail is classified from the
transcript (not from answered_by).

  --timeout SECONDS         Live-call poll timeout (default: 720)
  --interval SECONDS        Live-call poll interval (default: 10)
  --rec-interval SECONDS    Recordings poll interval (default: 15)
  --keep                    Keep local audio and the Telnyx recording (default)
  --keep-audio              Copy audio to recordings/ (default)
  --keep-remote             Leave the Telnyx recording in place (default)
  --delete-remote           DELETE the Telnyx recording after STT
  --no-keep-audio           Do not copy audio to recordings/

Required environment:
  TELNYX_API_KEY
  XAI_API_KEY               xAI key for POST /v1/stt (secure-secret flow)

Optional / auto-resolved:
  TELNYX_ACCOUNT_SID        if unset, GET /v2/whoami → data.organization_id

Example (fixture SID shape only):
  get-outcome.sh v3:exampleCallSid000000000000000000000000000
EOF
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

urlencode() {
  VAL="$1" python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["VAL"], safe=""))'
}

# Authenticated GET. Writes body to $1, prints HTTP status on stdout.
# Never uses curl -v (would leak Authorization).
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

# media_url is an S3 presigned URL (expires ~600s). Extra headers (including
# the Telnyx bearer) invalidate the signature. Download promptly, no auth.
# Fallback: Telnyx-hosted URL that 3xxs — follow Location without the bearer.
download_media() {
  local dest="$1"
  local media_url="$2"
  local hdr="${WORKDIR}/media.hdr"
  local code loc
  code="$(
    curl -sSg \
      -D "$hdr" \
      -o "$dest" \
      -w '%{http_code}' \
      --max-time 60 \
      "$media_url"
  )" || true
  case "$code" in
    200)
      echo "200"
      return 0
      ;;
    301|302|303|307|308)
      loc="$(
        python3 -c '
import sys
from urllib.parse import urljoin
hdr_path, base = sys.argv[1], sys.argv[2]
loc=""
with open(hdr_path,"rb") as f:
    for raw in f:
        line=raw.decode("iso-8859-1","replace")
        if line.lower().startswith("location:"):
            loc=line.split(":",1)[1].strip()
print(urljoin(base, loc) if loc else "")
' "$hdr" "$media_url"
      )"
      if [ -z "$loc" ]; then
        echo "$code"
        return 0
      fi
      curl -sSg \
        -o "$dest" \
        -w '%{http_code}' \
        -L \
        --max-time 60 \
        "$loc"
      return 0
      ;;
    *)
      echo "${code:-000}"
      return 0
      ;;
  esac
}

# Sniff a container format so STT can auto-detect (do not set audio_format
# for MP3/WAV — docs: container formats are auto-detected).
# https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
sniff_audio_name() {
  local src="$1"
  python3 -c '
import os,sys
path=sys.argv[1]
with open(path,"rb") as f:
    head=f.read(16)
base=os.path.basename(path)
if head.startswith(b"RIFF") and b"WAVE" in head:
    print(base+".wav")
elif head.startswith(b"ID3") or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
    print(base+".mp3")
elif head.startswith(b"OggS"):
    print(base+".ogg")
elif head.startswith(b"fLaC"):
    print(base+".flac")
else:
    print(base+".mp3")
' "$src"
}

# POST the recording to xAI STT. file MUST be the last multipart field.
# https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
xai_stt() {
  local audio_path="$1"
  local filename="$2"
  local out_file="$3"
  curl -sSg \
    -o "$out_file" \
    -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${XAI_API_KEY}" \
    -F "multichannel=true" \
    -F "format=true" \
    -F "language=en" \
    -F "file=@${audio_path};filename=${filename}" \
    "https://api.x.ai/v1/stt"
}

# Print per-channel text. Empty channels AND empty top-level text is failure.
print_stt_channels() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
lang=d.get("language") or ""
dur=d.get("duration")
if lang or dur is not None:
    print("STT language=%s duration=%s" % (lang, dur))
channels=d.get("channels") or []
chan_texts=[(ch.get("text") or "").strip() for ch in channels]
top=(d.get("text") or "").strip()
if not any(chan_texts) and not top:
    sys.stderr.write("error: empty STT transcript (all channel texts and top-level text are empty)\n")
    sys.exit(1)
if any(chan_texts):
    for ch in channels:
        print("channel %s:" % ch.get("index"))
        print(ch.get("text") or "")
        print("")
    sys.exit(0)
print(top)
'
}

# Write sid<TAB>media_url for recordings that are completed AND have media_url.
# Never prints media_url to stdout (writes a private tsv only).
write_completed_media_tsv() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
out=sys.argv[1]
rows=[]
for r in (d.get("recordings") or []):
    url=(r.get("media_url") or "").strip()
    sid=r.get("sid") or ""
    if r.get("status")=="completed" and url and sid:
        rows.append((sid, url))
with open(out,"w") as f:
    for sid, url in rows:
        f.write("%s\t%s\n" % (sid, url))
print(len(rows))
' "${WORKDIR}/completed.tsv" <"${WORKDIR}/recordings.json"
}

summarize_recordings() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
recs=d.get("recordings") or []
print("Recordings: %d" % len(recs))
for i, r in enumerate(recs, 1):
    url=(r.get("media_url") or "").strip()
    has="yes" if url else "no"
    print("  [%d] sid=%s status=%s channels=%s source=%s duration=%s has_media=%s" % (
        i, r.get("sid"), r.get("status"), r.get("channels"),
        r.get("source"), r.get("duration"), has))
' <"${WORKDIR}/recordings.json"
}

fetch_recordings_json() {
  local code
  code="$(telnyx_get "${WORKDIR}/recordings.json" "$RECORDINGS_URL")"
  if [ "$code" != "200" ]; then
    echo "error: fetch-recordings-for-a-call HTTP ${code} (outcome failed)" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/recordings.json" >&2
    exit 1
  fi
}

# DELETE .../Recordings/{recording_sid}.json — 204 on success.
# https://developers.telnyx.com/api-reference/texml-rest-commands/delete-recording-resource
delete_remote_recording() {
  local rec_sid="$1"
  local rec_enc del_url code
  rec_enc="$(urlencode "$rec_sid")"
  del_url="https://api.telnyx.com/v2/texml/Accounts/${ACCOUNT_SID_ENC}/Recordings/${rec_enc}.json"
  code="$(
    curl -sSg \
      -o "${WORKDIR}/delete.json" \
      -w '%{http_code}' \
      -X DELETE \
      -H "Authorization: Bearer ${TELNYX_API_KEY}" \
      -H "Accept: application/json" \
      "$del_url"
  )" || code="000"
  if [ "$code" = "204" ] || [ "$code" = "200" ]; then
    echo "Deleted Telnyx recording ${rec_sid} (HTTP ${code})"
  else
    echo "warning: failed to delete Telnyx recording ${rec_sid} (HTTP ${code}); not fatal" >&2
  fi
}

sanitize_rec_sid() {
  local rec_sid="$1"
  if [[ ! "$rec_sid" =~ ^[A-Za-z0-9:_-]+$ ]]; then
    echo "error: recording sid contains characters not allowed in a filesystem path" >&2
    exit 2
  fi
}

TIMEOUT_SECS=720
INTERVAL_SECS=10
REC_INTERVAL_SECS=15
REC_LIMIT=180
KEEP_AUDIO=1
KEEP_REMOTE=1
CALL_SID=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --timeout)
      if [ $# -lt 2 ]; then
        echo "error: --timeout requires a value" >&2
        exit 2
      fi
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    --interval)
      if [ $# -lt 2 ]; then
        echo "error: --interval requires a value" >&2
        exit 2
      fi
      INTERVAL_SECS="$2"
      shift 2
      ;;
    --rec-interval)
      if [ $# -lt 2 ]; then
        echo "error: --rec-interval requires a value" >&2
        exit 2
      fi
      REC_INTERVAL_SECS="$2"
      shift 2
      ;;
    --keep)
      KEEP_AUDIO=1
      KEEP_REMOTE=1
      shift
      ;;
    --keep-audio)
      KEEP_AUDIO=1
      shift
      ;;
    --keep-remote)
      KEEP_REMOTE=1
      shift
      ;;
    --delete-remote)
      KEEP_REMOTE=0
      shift
      ;;
    --no-keep-audio)
      KEEP_AUDIO=0
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
      if [ -n "$CALL_SID" ]; then
        echo "error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      CALL_SID="$1"
      shift
      ;;
  esac
done

if [ -z "$CALL_SID" ]; then
  usage >&2
  exit 2
fi

case "$TIMEOUT_SECS" in
  ''|*[!0-9]*) echo "error: --timeout must be an integer" >&2; exit 2 ;;
esac
case "$INTERVAL_SECS" in
  ''|*[!0-9]*) echo "error: --interval must be an integer" >&2; exit 2 ;;
esac
case "$REC_INTERVAL_SECS" in
  ''|*[!0-9]*) echo "error: --rec-interval must be an integer" >&2; exit 2 ;;
esac
if [ "$INTERVAL_SECS" -lt 1 ] || [ "$REC_INTERVAL_SECS" -lt 1 ]; then
  echo "error: poll intervals must be >= 1" >&2
  exit 2
fi

require_env TELNYX_API_KEY

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to parse JSON" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

resolve_account_sid
ACCOUNT_SID_ENC="$(urlencode "$TELNYX_ACCOUNT_SID")"
CALL_SID_ENC="$(urlencode "$CALL_SID")"

# REST equivalents of retrieve_calls_accounts_texml_calls and
# recordings_json_calls_accounts_texml_recordings_json.
CALL_URL="https://api.telnyx.com/v2/texml/Accounts/${ACCOUNT_SID_ENC}/Calls/${CALL_SID_ENC}"
# https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-recordings-for-a-call
RECORDINGS_URL="${CALL_URL}/Recordings.json"

WORKDIR="$(mktemp -d)"
export WORKDIR
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# Terminal statuses from CallResource.status:
#   ringing | in-progress | canceled | completed | failed | busy | no-answer
# https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-a-call
is_terminal() {
  case "$1" in
    canceled|completed|failed|busy|no-answer) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Polling call status every ${INTERVAL_SECS}s (timeout ${TIMEOUT_SECS}s)"

ELAPSED=0
STATUS=""

while :; do
  CODE="$(telnyx_get "${WORKDIR}/call.json" "$CALL_URL")"
  if [ "$CODE" != "200" ]; then
    echo "error: fetch-a-call HTTP ${CODE} (outcome failed)" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/call.json" >&2
    exit 1
  fi
  STATUS="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("status") or "")
' <"${WORKDIR}/call.json"
  )"
  echo "  status=${STATUS} (${ELAPSED}s)"
  if is_terminal "$STATUS"; then
    break
  fi
  if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
    break
  fi
  sleep "$INTERVAL_SECS"
  ELAPSED=$((ELAPSED + INTERVAL_SECS))
done

echo
echo "Call SID:    ${CALL_SID}"
echo "Status:      ${STATUS}"
echo "Voicemail:   classify from the transcript (AMD/answered_by unused)"

CALL_TIMED_OUT=0
if ! is_terminal "$STATUS"; then
  CALL_TIMED_OUT=1
  echo "Live-call poll reached ${TIMEOUT_SECS}s still non-terminal; doing one recordings check."
fi

echo
echo "Fetching recordings"

if [ "$CALL_TIMED_OUT" -eq 1 ]; then
  fetch_recordings_json
  COMPLETED_N="$(write_completed_media_tsv)"
  summarize_recordings
  if [ "$COMPLETED_N" = "0" ]; then
    echo "error: outcome unknown — live call still ${STATUS:-unset} at ${TIMEOUT_SECS}s and no completed recording with media_url" >&2
    exit 3
  fi
else
  REC_WAIT=0
  COMPLETED_N=0
  while :; do
    fetch_recordings_json
    COMPLETED_N="$(write_completed_media_tsv)"
    if [ "$COMPLETED_N" != "0" ]; then
      break
    fi
    COUNT="$(
      python3 -c '
import json,sys
d=json.load(sys.stdin)
print(len(d.get("recordings") or []))
' <"${WORKDIR}/recordings.json"
    )"
    echo "  recordings=${COUNT} completed_with_media=0 (${REC_WAIT}s)"
    if [ "$REC_WAIT" -ge "$REC_LIMIT" ]; then
      break
    fi
    sleep "$REC_INTERVAL_SECS"
    REC_WAIT=$((REC_WAIT + REC_INTERVAL_SECS))
  done
  summarize_recordings
  if [ "$COMPLETED_N" = "0" ]; then
    echo "error: outcome unknown — no completed recording with media_url after ${REC_LIMIT}s" >&2
    exit 3
  fi
fi

if [ -z "${XAI_API_KEY:-}" ]; then
  # Persist the first completed recording so a later STT run can use it.
  while IFS="$(printf '\t')" read -r rec_sid media_url; do
    sanitize_rec_sid "$rec_sid"
    dest="${WORKDIR}/recording-${rec_sid}"
    DL_CODE="$(download_media "$dest" "$media_url")"
    SIZE="$(wc -c <"$dest" | tr -d ' ')"
    if [ "$DL_CODE" = "200" ] && [ "$SIZE" -gt 0 ]; then
      filename="$(sniff_audio_name "$dest")"
      mkdir -p recordings
      kept="recordings/phonezero-recording-${filename}"
      cp "$dest" "$kept"
      echo "Recording file: ${kept}"
    fi
    break
  done <"${WORKDIR}/completed.tsv"
  echo "error: transcript step requires XAI_API_KEY via the Grok Bot secure-secret flow (never paste the key in chat)" >&2
  exit 2
fi

while IFS="$(printf '\t')" read -r rec_sid media_url; do
  sanitize_rec_sid "$rec_sid"
  dest="${WORKDIR}/recording-${rec_sid}"
  DL_CODE="$(download_media "$dest" "$media_url")"
  SIZE="$(wc -c <"$dest" | tr -d ' ')"
  if [ "$DL_CODE" != "200" ] || [ "$SIZE" -eq 0 ]; then
    echo "error: recording ${rec_sid} download HTTP ${DL_CODE} (${SIZE} bytes) (outcome failed)" >&2
    exit 1
  fi
  filename="$(sniff_audio_name "$dest")"
  named="${WORKDIR}/${filename}"
  mv "$dest" "$named"
  dest="$named"
  echo "Downloaded recording ${rec_sid} (${SIZE} bytes)"

  if [ "$KEEP_AUDIO" -eq 1 ]; then
    mkdir -p recordings
    kept="recordings/phonezero-recording-${filename}"
    cp "$dest" "$kept"
    echo "Kept audio: ${kept}"
  fi

  echo
  echo "Transcribing with xAI STT (multichannel=true)..."
  STT_CODE="$(xai_stt "$dest" "$filename" "${WORKDIR}/stt.json")"
  if [ "$STT_CODE" != "200" ]; then
    echo "error: xAI STT HTTP ${STT_CODE} (outcome failed)" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/stt.json" >&2
    exit 1
  fi
  print_stt_channels <"${WORKDIR}/stt.json"

  if [ "$KEEP_REMOTE" -eq 0 ]; then
    delete_remote_recording "$rec_sid"
  else
    echo "Kept remote Telnyx recording ${rec_sid} (--keep-remote)"
  fi
done <"${WORKDIR}/completed.tsv"

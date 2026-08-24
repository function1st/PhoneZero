#!/usr/bin/env bash
# get-outcome.sh — poll a TeXML call to a terminal status, download the
# Dial-verb recording, and transcribe it with xAI STT (the default
# outcome path).
#
# Call status (eventually consistent):
#   GET /v2/texml/Accounts/{account_sid}/Calls/{call_sid}
#   https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-a-call
#   AMD verdict is answered_by on that resource (human | machine | not_sure),
#   because place-call.sh sends AsyncAmd=true and omits StatusCallback.
#
# Recordings for that call:
#   GET /v2/texml/Accounts/{account_sid}/Calls/{call_sid}/Recordings.json
#   https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-recordings-for-a-call
#
# Default transcript: POST https://api.x.ai/v1/stt (multipart).
#   https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
#   Dial-verb recordings are not auto-transcribed by Telnyx (only <Record
#   transcription="true"> and the <Transcription> verb create them).
#   https://developers.telnyx.com/docs/voice/texml/rest-api/transcripts
#
# Required env (never echoed):
#   TELNYX_API_KEY
#   TELNYX_ACCOUNT_SID
# Optional:
#   XAI_API_KEY   — required for the STT step (Grok Bot secure-secret flow)
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: get-outcome.sh [--timeout SECONDS] [--interval SECONDS] [--keep-audio] CALL_SID

Poll a TeXML call until it reaches a terminal status, download its
recording(s), and transcribe with xAI STT (multichannel). Prints
answered_by (AMD) and the per-channel transcript.

  --timeout SECONDS    Max seconds to wait for a terminal call status
                       (default: 720)
  --interval SECONDS   Poll interval (default: 5)
  --keep-audio         Keep downloaded recording files in the current
                       directory (default: delete temp audio on exit)

Required environment:
  TELNYX_API_KEY
  TELNYX_ACCOUNT_SID

Optional environment:
  XAI_API_KEY          xAI key for POST /v1/stt. If unset, the recording
                       path is printed and the transcript step is skipped
                       with a one-line secure-secret instruction.

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

# Authenticated GET. Writes body to $1, prints HTTP status on stdout.
# Never uses curl -v (would leak Authorization).
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

# Download a recording media URL (may require the same bearer).
# Record-verb docs say callback RecordingUrls expire in 10 minutes; API/portal
# copies remain. We still fetch immediately.
# https://developers.telnyx.com/docs/voice/programmable-voice/texml-verbs/record
download_media() {
  local dest="$1"
  local media_url="$2"
  local code
  code="$(
    curl -sS \
      -o "$dest" \
      -w '%{http_code}' \
      -L \
      -H "Authorization: Bearer ${TELNYX_API_KEY}" \
      "$media_url"
  )"
  echo "$code"
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
  # -F order: options first, file last (fields after file may be ignored).
  curl -sS \
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

print_stt_channels() {
  python3 -c '
import json,sys
d=json.load(sys.stdin)
lang=d.get("language") or ""
dur=d.get("duration")
if lang or dur is not None:
    print("STT language=%s duration=%s" % (lang, dur))
channels=d.get("channels") or []
if channels:
    for ch in channels:
        idx=ch.get("index")
        print("channel %s:" % idx)
        print(ch.get("text") or "")
        print("")
    sys.exit(0)
# Fallback if the server omitted channels (e.g. mono file).
text=d.get("text") or ""
if text:
    print(text)
    sys.exit(0)
sys.stderr.write("error: STT response had neither channels[] nor text\n")
sys.exit(1)
'
}

# Best-effort Telnyx transcription lookup. Dial-verb recordings do not
# create these; any miss is silent.
# https://developers.telnyx.com/docs/voice/texml/rest-api/transcripts
maybe_telnyx_transcription() {
  local url="https://api.telnyx.com/v2/texml/Accounts/${TELNYX_ACCOUNT_SID}/Transcriptions.json?PageSize=20"
  local code
  code="$(telnyx_get "${WORKDIR}/texml_tx.json" "$url" || true)"
  if [ "${code:-}" != "200" ]; then
    return 0
  fi
  CALL_SID="$CALL_SID" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
call=os.environ["CALL_SID"]
for t in (d.get("transcriptions") or []):
    if t.get("call_sid")!=call and t.get("CallSid")!=call:
        continue
    text=t.get("transcription_text") or ""
    if text:
        print("Telnyx transcription (unexpected for DialVerb; using as extra):")
        print(text)
        sys.exit(0)
' <"${WORKDIR}/texml_tx.json" 2>/dev/null || true
}

TIMEOUT_SECS=720
INTERVAL_SECS=5
KEEP_AUDIO=0
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
    --keep-audio)
      KEEP_AUDIO=1
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
if [ "$INTERVAL_SECS" -lt 1 ]; then
  echo "error: --interval must be >= 1" >&2
  exit 2
fi

require_env TELNYX_API_KEY
require_env TELNYX_ACCOUNT_SID

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to parse JSON" >&2
  exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl is required" >&2
  exit 2
fi

# CallSid is a path segment (often v3:...). Percent-encode via python.
CALL_SID_ENC="$(
  CALL_SID="$CALL_SID" python3 -c 'import os,urllib.parse; print(urllib.parse.quote(os.environ["CALL_SID"], safe=""))'
)"

CALL_URL="https://api.telnyx.com/v2/texml/Accounts/${TELNYX_ACCOUNT_SID}/Calls/${CALL_SID_ENC}"
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

echo "Polling call status: ${CALL_URL}"
echo "(GET is eventually consistent — fetch-a-call docs)"

ELAPSED=0
STATUS=""
ANSWERED_BY=""

while [ "$ELAPSED" -le "$TIMEOUT_SECS" ]; do
  CODE="$(telnyx_get "${WORKDIR}/call.json" "$CALL_URL")"
  if [ "$CODE" != "200" ]; then
    echo "error: fetch-a-call HTTP ${CODE}" >&2
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
  ANSWERED_BY="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d.get("answered_by") or "")
' <"${WORKDIR}/call.json"
  )"
  echo "  status=${STATUS}${ANSWERED_BY:+ answered_by=${ANSWERED_BY}} (${ELAPSED}s)"
  if is_terminal "$STATUS"; then
    break
  fi
  sleep "$INTERVAL_SECS"
  ELAPSED=$((ELAPSED + INTERVAL_SECS))
done

if ! is_terminal "$STATUS"; then
  echo "error: call did not reach a terminal status within ${TIMEOUT_SECS}s (last status=${STATUS})" >&2
  exit 1
fi

echo
echo "Call SID:    ${CALL_SID}"
echo "Status:      ${STATUS}"
if [ -n "$ANSWERED_BY" ]; then
  # answered_by is where the AMD verdict lands when AsyncAmd=true and
  # StatusCallback is omitted (zero-server). Enum: human | machine | not_sure.
  # https://developers.telnyx.com/api-reference/texml-rest-commands/fetch-a-call
  echo "Answered-by: ${ANSWERED_BY}  (AMD; GET call resource answered_by)"
else
  echo "Answered-by: (empty — AMD result not populated on this resource yet)"
fi

# Recordings can lag call completion. Poll until we see a completed item or
# the remaining timeout budget is exhausted.
echo
echo "Fetching recordings: ${RECORDINGS_URL}"

REC_WAIT=0
REC_LIMIT=180
HAVE_COMPLETED=0

while [ "$REC_WAIT" -le "$REC_LIMIT" ]; do
  CODE="$(telnyx_get "${WORKDIR}/recordings.json" "$RECORDINGS_URL")"
  if [ "$CODE" != "200" ]; then
    echo "error: fetch-recordings-for-a-call HTTP ${CODE}" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/recordings.json" >&2
    exit 1
  fi
  HAVE_COMPLETED="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
recs=d.get("recordings") or []
print(1 if any((r.get("status")=="completed") for r in recs) else 0)
' <"${WORKDIR}/recordings.json"
  )"
  if [ "$HAVE_COMPLETED" = "1" ]; then
    break
  fi
  COUNT="$(
    python3 -c '
import json,sys
d=json.load(sys.stdin)
print(len(d.get("recordings") or []))
' <"${WORKDIR}/recordings.json"
  )"
  echo "  recordings=${COUNT} (waiting for status=completed, ${REC_WAIT}s)"
  sleep "$INTERVAL_SECS"
  REC_WAIT=$((REC_WAIT + INTERVAL_SECS))
done

python3 -c '
import json,sys
d=json.load(sys.stdin)
recs=d.get("recordings") or []
print("Recordings: %d" % len(recs))
for i, r in enumerate(recs, 1):
    print("  [%d] sid=%s status=%s channels=%s source=%s duration=%s" % (
        i, r.get("sid"), r.get("status"), r.get("channels"),
        r.get("source"), r.get("duration")))
    print("      media_url=%s" % (r.get("media_url") or "(none)"))
' <"${WORKDIR}/recordings.json"

REC_COUNT="$(
  python3 -c '
import json,sys
d=json.load(sys.stdin)
print(len(d.get("recordings") or []))
' <"${WORKDIR}/recordings.json"
)"
if [ "$REC_COUNT" = "0" ]; then
  echo "error: no recordings for this call after ${REC_LIMIT}s" >&2
  exit 1
fi

python3 -c '
import json,sys
d=json.load(sys.stdin)
for r in (d.get("recordings") or []):
    url=r.get("media_url") or ""
    sid=r.get("sid") or "unknown"
    if url:
        print("%s\t%s" % (sid, url))
' <"${WORKDIR}/recordings.json" >"${WORKDIR}/media.tsv"

if [ ! -s "${WORKDIR}/media.tsv" ]; then
  echo "error: recordings listed but none had a media_url" >&2
  exit 1
fi

MISSING_STT_KEY=0

while IFS="$(printf '\t')" read -r rec_sid media_url; do
  dest="${WORKDIR}/recording-${rec_sid}"
  DL_CODE="$(download_media "$dest" "$media_url")"
  SIZE="$(wc -c <"$dest" | tr -d ' ')"
  if [ "$DL_CODE" != "200" ] || [ "$SIZE" -eq 0 ]; then
    echo "error: recording ${rec_sid} download HTTP ${DL_CODE} (${SIZE} bytes)" >&2
    echo "       media_url=${media_url}" >&2
    exit 1
  fi
  filename="$(sniff_audio_name "$dest")"
  named="${WORKDIR}/${filename}"
  mv "$dest" "$named"
  dest="$named"
  echo "Downloaded recording ${rec_sid} (${SIZE} bytes) -> ${dest}"

  if [ "$KEEP_AUDIO" -eq 1 ]; then
    kept="./phonezero-recording-${filename}"
    cp "$dest" "$kept"
    KEPT_FILES+=("$kept")
    echo "Kept audio: ${kept}"
  fi

  if [ -z "${XAI_API_KEY:-}" ]; then
    MISSING_STT_KEY=1
    # Temp dir is deleted on exit; persist a cwd copy so the printed path
    # survives for a later STT run after the secure-secret flow.
    if [ "$KEEP_AUDIO" -ne 1 ]; then
      kept="./phonezero-recording-${filename}"
      cp "$dest" "$kept"
    fi
    echo "Recording file: ${kept}"
    continue
  fi

  echo
  echo "Transcribing with xAI STT (multichannel=true)..."
  STT_CODE="$(xai_stt "$dest" "$filename" "${WORKDIR}/stt.json")"
  if [ "$STT_CODE" != "200" ]; then
    echo "error: xAI STT HTTP ${STT_CODE}" >&2
    python3 -c 'import sys; print(sys.stdin.read()[:400])' <"${WORKDIR}/stt.json" >&2
    exit 1
  fi
  print_stt_channels <"${WORKDIR}/stt.json"
done <"${WORKDIR}/media.tsv"

# Silent unless a Dial-verb recording somehow has a Telnyx transcription.
maybe_telnyx_transcription

if [ "$MISSING_STT_KEY" -eq 1 ]; then
  echo "Transcript step needs XAI_API_KEY via the Grok Bot secure-secret flow (never paste the key in chat)."
fi

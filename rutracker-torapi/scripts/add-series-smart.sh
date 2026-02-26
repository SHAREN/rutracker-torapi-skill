#!/usr/bin/env bash
set -euo pipefail

# Smart add torrent to qBittorrent with:
# - free-space check (torrent size + 5 GiB)
# - auto paused add when low space
# - sequential + first/last piece flags for movies/series
# - file priorities for series: ep1=max, ep2=high, rest=normal
#
# Usage:
#   add-series-smart.sh --id 6804911
#   add-series-smart.sh --id 6804911 --size-bytes 7290000000 --name "A Knight ..."   # fast-path
#   add-series-smart.sh --magnet 'magnet:?xt=urn:btih:...'
#
# Requires env:
#   QB_WEB_URL QB_USERNAME QB_PASSWORD

TORAPI_BASE="${TORAPI_BASE:-https://torapi.vercel.app}"
RESERVE_BYTES=$((5*1024*1024*1024))

need_bin(){ command -v "$1" >/dev/null 2>&1 || { echo "missing_bin:$1" >&2; exit 2; }; }
need_bin curl; need_bin jq; need_bin python3

: "${QB_WEB_URL:?QB_WEB_URL is required}"
: "${QB_USERNAME:?QB_USERNAME is required}"
: "${QB_PASSWORD:?QB_PASSWORD is required}"

TID=""
MAGNET_INPUT=""
SIZE_BYTES_INPUT=""
NAME_INPUT=""
ASSUME_SERIES="auto" # auto|yes|no

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) TID="${2:-}"; shift 2;;
    --magnet) MAGNET_INPUT="${2:-}"; shift 2;;
    --size-bytes) SIZE_BYTES_INPUT="${2:-}"; shift 2;;
    --name) NAME_INPUT="${2:-}"; shift 2;;
    --series) ASSUME_SERIES="yes"; shift;;
    --movie) ASSUME_SERIES="no"; shift;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

if [[ -z "$TID" && -z "$MAGNET_INPUT" ]]; then
  echo "Provide --id or --magnet" >&2
  exit 1
fi

DETAILS='[]'
HASH=""
MAGNET="$MAGNET_INPUT"
TORRENT_SIZE_BYTES=0
NAME="$NAME_INPUT"

if [[ -n "$TID" ]]; then
  # Fast-path: if size is provided, skip heavy size parsing from file list
  DETAILS=$(curl -s "$TORAPI_BASE/api/search/id/rutracker?query=$TID")
  MAGNET=$(echo "$DETAILS" | jq -r '.[0].Magnet // empty')
  HASH=$(echo "$DETAILS" | jq -r '.[0].Hash // empty' | tr '[:upper:]' '[:lower:]')
  [[ -z "$NAME" ]] && NAME=$(echo "$DETAILS" | jq -r '.[0].Name // empty')

  if [[ -n "$SIZE_BYTES_INPUT" ]]; then
    TORRENT_SIZE_BYTES="$SIZE_BYTES_INPUT"
  else
    # Sum file sizes from TorAPI details when available
    TORRENT_SIZE_BYTES=$(python3 - <<'PY' "$DETAILS"
import json,sys,re
obj=json.loads(sys.argv[1])
item=obj[0] if isinstance(obj,list) and obj else {}
files=item.get('Files') or []
units={'b':1,'kb':1024,'mb':1024**2,'gb':1024**3,'tb':1024**4}
total=0
for f in files:
    s=str((f or {}).get('size','')).strip().replace(',', '.')
    m=re.search(r'([0-9]+(?:\.[0-9]+)?)\s*([kmgt]?b)', s.lower())
    if not m:
        continue
    total += int(float(m.group(1))*units[m.group(2)])
print(total)
PY
)
  fi
fi

if [[ -z "$MAGNET" ]]; then
  echo "magnet_not_found" >&2
  exit 1
fi

if [[ -n "$SIZE_BYTES_INPUT" && "$TORRENT_SIZE_BYTES" -eq 0 ]]; then
  TORRENT_SIZE_BYTES="$SIZE_BYTES_INPUT"
fi

if [[ -z "$HASH" ]]; then
  HASH=$(python3 - <<'PY' "$MAGNET"
import re,sys
m=re.search(r'btih:([A-Fa-f0-9]{40})', sys.argv[1])
print((m.group(1).lower() if m else ''))
PY
)
fi

COOKIE=$(mktemp)
cleanup(){ rm -f "$COOKIE"; }
trap cleanup EXIT

curl -sk -c "$COOKIE" \
  --data-urlencode "username=$QB_USERNAME" \
  --data-urlencode "password=$QB_PASSWORD" \
  "$QB_WEB_URL/api/v2/auth/login" >/tmp/qb_login_smart.txt

FREE_BYTES=$(curl -sk -b "$COOKIE" "$QB_WEB_URL/api/v2/sync/maindata" | jq -r '.server_state.free_space_on_disk // 0')
REQUIRED_BYTES=$((TORRENT_SIZE_BYTES + RESERVE_BYTES))
ADD_PAUSED=false
if [[ "$TORRENT_SIZE_BYTES" -gt 0 && "$FREE_BYTES" -lt "$REQUIRED_BYTES" ]]; then
  ADD_PAUSED=true
fi

ADD_RESP=$(curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/add" \
  --data-urlencode "urls=$MAGNET" \
  --data-urlencode "paused=$ADD_PAUSED")

# Fetch torrent info with minimal retries (reduce extra API calls)
sleep 1
INFO=$(curl -sk -b "$COOKIE" "$QB_WEB_URL/api/v2/torrents/info?hashes=$HASH")
COUNT=$(echo "$INFO" | jq 'length')
if [[ "$COUNT" -eq 0 ]]; then
  sleep 1
  INFO=$(curl -sk -b "$COOKIE" "$QB_WEB_URL/api/v2/torrents/info?hashes=$HASH")
  COUNT=$(echo "$INFO" | jq 'length')
fi

# Enable sequential + first/last (movie/series)
SEQ=$(echo "$INFO" | jq -r '.[0].seq_dl // false')
FLP=$(echo "$INFO" | jq -r '.[0].f_l_piece_prio // false')
if [[ "$SEQ" != "true" ]]; then
  curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/toggleSequentialDownload" --data-urlencode "hashes=$HASH" >/dev/null
  SEQ=true
fi
if [[ "$FLP" != "true" ]]; then
  curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/toggleFirstLastPiecePrio" --data-urlencode "hashes=$HASH" >/dev/null
  FLP=true
fi

# Decide if series and set file priorities
FILES_JSON=$(curl -sk -b "$COOKIE" "$QB_WEB_URL/api/v2/torrents/files?hash=$HASH")
PRIO_PLAN=$(python3 - <<'PY' "$FILES_JSON" "$ASSUME_SERIES"
import json,re,sys
files=json.loads(sys.argv[1]) if sys.argv[1].strip() else []
assume=sys.argv[2]
vid_ext={'.mkv','.mp4','.avi','.mov','.m4v','.ts'}
items=[]
for f in files:
    n=f.get('name','')
    i=f.get('index')
    low=n.lower()
    if any(low.endswith(e) for e in vid_ext) and isinstance(i,int):
        # detect episode number by s01e02, e02, ep02, 02x03
        m=(re.search(r's\d{1,2}e(\d{1,3})',low) or
           re.search(r'\be[p]?\s?(\d{1,3})\b',low) or
           re.search(r'\b(\d{1,2})x(\d{1,3})\b',low))
        ep=int(m.group(1 if m.lastindex==1 else 2)) if m else 10**6
        items.append((ep,n,i))
items.sort(key=lambda t:(t[0],t[1]))
ids=[i for _,_,i in items]
is_series = len(ids) >= 2
if assume == 'yes':
    is_series = True
elif assume == 'no':
    is_series = False
if not is_series or not ids:
    print('')
else:
    first=ids[0]
    second=ids[1] if len(ids)>1 else None
    rest=ids[2:] if len(ids)>2 else []
    out=[f'first={first}']
    if second is not None: out.append(f'second={second}')
    if rest: out.append('rest='+'|'.join(map(str,rest)))
    print('\n'.join(out))
PY
)

if [[ -n "$PRIO_PLAN" ]]; then
  FIRST=$(echo "$PRIO_PLAN" | awk -F= '/^first=/{print $2}')
  SECOND=$(echo "$PRIO_PLAN" | awk -F= '/^second=/{print $2}')
  REST=$(echo "$PRIO_PLAN" | awk -F= '/^rest=/{print $2}')
  [[ -n "$FIRST" ]] && curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/filePrio" --data-urlencode "hash=$HASH" --data-urlencode "id=$FIRST" --data-urlencode "priority=7" >/dev/null
  [[ -n "$SECOND" ]] && curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/filePrio" --data-urlencode "hash=$HASH" --data-urlencode "id=$SECOND" --data-urlencode "priority=6" >/dev/null
  [[ -n "$REST" ]] && curl -sk -b "$COOKIE" -X POST "$QB_WEB_URL/api/v2/torrents/filePrio" --data-urlencode "hash=$HASH" --data-urlencode "id=$REST" --data-urlencode "priority=1" >/dev/null
fi

STATE=$(echo "$INFO" | jq -r '.[0].state // "unknown"')
NAME_FINAL=$(echo "$INFO" | jq -r '.[0].name // empty')

INPUT_MODE="full"
if [[ -n "$SIZE_BYTES_INPUT" ]]; then INPUT_MODE="fast"; fi

jq -n \
  --arg name "${NAME_FINAL:-$NAME}" \
  --arg hash "$HASH" \
  --arg state "$STATE" \
  --arg addResp "$ADD_RESP" \
  --arg inputMode "$INPUT_MODE" \
  --argjson freeBytes "${FREE_BYTES:-0}" \
  --argjson torrentBytes "${TORRENT_SIZE_BYTES:-0}" \
  --argjson requiredBytes "${REQUIRED_BYTES:-0}" \
  --argjson pausedAdd "$ADD_PAUSED" \
  --argjson sequential "$SEQ" \
  --argjson firstLast "$FLP" \
  --arg prioPlan "$PRIO_PLAN" \
  '{input_mode:$inputMode,name:$name,hash:$hash,state:$state,add_response:$addResp,free_bytes:$freeBytes,torrent_bytes:$torrentBytes,required_bytes:$requiredBytes,added_paused:$pausedAdd,sequential_download:$sequential,first_last_piece_prio:$firstLast,series_priority_plan:$prioPlan}'

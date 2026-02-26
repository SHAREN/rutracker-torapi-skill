#!/usr/bin/env bash
set -euo pipefail

# Unified TorAPI search with sorting by seeds desc.
# Usage:
#   search-torrents-sorted.sh "query" [limit] [category] [provider]
# Providers: rutracker|kinozal|rutor|nonameclub

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"query\" [limit] [category] [provider]" >&2
  exit 1
fi

QUERY="$1"
LIMIT="${2:-10}"
CATEGORY="${3:-0}"
PROVIDER="${4:-rutracker}"

case "$PROVIDER" in
  rutracker|kinozal|rutor|nonameclub) ;;
  *) echo "Unsupported provider: $PROVIDER" >&2; exit 1;;
esac

ENC_QUERY=$(python3 - <<'PY' "$QUERY"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)

URL="https://torapi.vercel.app/api/search/title/${PROVIDER}?query=${ENC_QUERY}&category=${CATEGORY}&page=0"

curl -s "$URL" \
| jq --argjson limit "$LIMIT" '
  map(. + {SeedsNum: ((.Seeds // "0") | tostring | gsub("[^0-9]"; "") | if .=="" then "0" else . end | tonumber)})
  | sort_by(.SeedsNum)
  | reverse
  | .[:$limit]
  | map(del(.SeedsNum))
'

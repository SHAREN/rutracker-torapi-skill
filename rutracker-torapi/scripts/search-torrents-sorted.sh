#!/usr/bin/env bash
set -euo pipefail

# Unified multi-provider TorAPI search with sorting by seeds desc.
# Usage:
#   search-torrents-sorted.sh "query" [limit] [category] [provider|all]
# Providers: rutracker|kinozal|rutor|nonameclub|all

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 \"query\" [limit] [category] [provider|all]" >&2
  exit 1
fi

QUERY="$1"
LIMIT="${2:-10}"
CATEGORY="${3:-0}"
PROVIDER="${4:-all}"

PROVIDERS=(rutracker kinozal rutor nonameclub)

if [[ "$PROVIDER" != "all" ]]; then
  case "$PROVIDER" in
    rutracker|kinozal|rutor|nonameclub) PROVIDERS=("$PROVIDER") ;;
    *) echo "Unsupported provider: $PROVIDER" >&2; exit 1 ;;
  esac
fi

ENC_QUERY=$(python3 - <<'PY' "$QUERY"
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1]))
PY
)

for p in "${PROVIDERS[@]}"; do
  URL="https://torapi.vercel.app/api/search/title/${p}?query=${ENC_QUERY}&category=${CATEGORY}&page=0"
  curl -s "$URL" | jq --arg provider "$p" 'map(. + {Provider: $provider})'
done \
| jq -s --argjson limit "$LIMIT" '
  add
  | map(. + {
      SeedsNum: ((.Seeds // "0") | tostring | gsub("[^0-9]"; "") | if .=="" then "0" else . end | tonumber)
    })
  | sort_by(.SeedsNum)
  | reverse
  | .[:$limit]
  | map(del(.SeedsNum))
'

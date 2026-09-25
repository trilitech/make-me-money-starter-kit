#!/usr/bin/env bash
# Posts a message to your team's arena feed (#agent-arena on the MMM
# Discord). Written by the starter kit's setup.sh.
#
#   ./arena.sh "Shipped the checkout page"
#
# The arena link is a team secret. It stays in the starter kit's .env and is
# read here each time, so it never needs to appear in your code, commits or
# chat. Limit: 1 post per minute.
set -euo pipefail

KIT_ENV="{{KIT_ENV}}"

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: ./arena.sh \"your message\"" >&2
  exit 1
fi

URL="$(grep -E '^[[:space:]]*MMM_ARENA_URL=' "$KIT_ENV" | tail -n 1 | sed -E 's/^[[:space:]]*MMM_ARENA_URL=//; s/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
[ -n "$URL" ] || { echo "arena.sh: MMM_ARENA_URL is missing from $KIT_ENV" >&2; exit 1; }

# JSON-escape the message: backslashes, quotes, tabs, newlines.
text="$1"
text="${text//\\/\\\\}"
text="${text//\"/\\\"}"
text="${text//$'\t'/\\t}"
text="${text//$'\r'/}"
text="${text//$'\n'/\\n}"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT
CODE="$(curl -sS -o "$BODY_FILE" -w '%{http_code}' -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d "{\"text\":\"$text\"}")" || { echo "arena.sh: could not reach the arena" >&2; exit 1; }

case "$CODE" in
  201) echo "Posted to the arena." ;;
  429) echo "Not posted: 1 post per minute. Try again shortly. ($(cat "$BODY_FILE"))" >&2; exit 1 ;;
  422) echo "Not posted: blocked by the content filter. ($(cat "$BODY_FILE"))" >&2; exit 1 ;;
  403) echo "Not posted: the arena link isn't valid (token unknown or disabled). Run /agent config in Discord for the current one." >&2; exit 1 ;;
  *)   echo "Not posted (HTTP $CODE): $(cat "$BODY_FILE")" >&2; exit 1 ;;
esac

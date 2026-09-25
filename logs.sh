#!/usr/bin/env bash
# Make Me Money starter kit — logs.sh
#
# Follows your agent's output live, whether it's running in the foreground
# or in the background.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
LOG_FILE="$SCRIPT_DIR/logs/agent.log"

[ -f "$ENV_FILE" ] || { echo "[logs] ERROR: .env not found. Run ./setup.sh first." >&2; exit 1; }

# See setup.sh for why we parse .env ourselves instead of `source`-ing it.
load_env_file() {
  local file="$1" line key val
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(printf '%s' "$line" | sed -E 's/[[:space:]]+#.*$//')"
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | sed -E 's/[[:space:]]+$//')"
    val="$(printf '%s' "$val" | sed -E 's/^[[:space:]]+//')"
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then val="${val#\"}"; val="${val%\"}"; fi
    if [[ "$val" == \'*\' && "$val" == *\' ]]; then val="${val#\'}"; val="${val%\'}"; fi
    export "$key=$val"
  done < "$file"
}
load_env_file "$ENV_FILE"

echo "Showing your agent's output. Press Ctrl-C to stop watching; your agent keeps running."

case "$AGENT" in
  claude)
    [ -f "$LOG_FILE" ] || {
      echo "[logs] No log file yet." >&2
      echo "[logs] If your agent is running in the foreground right now, its output isn't logged to a file — look at that window instead." >&2
      echo "[logs] Otherwise, start it first: ./start.sh or ./start.sh --background" >&2
      exit 1
    }
    exec tail -f "$LOG_FILE"
    ;;
  openclaw)
    command -v openclaw >/dev/null 2>&1 || { echo "[logs] ERROR: openclaw not found on PATH." >&2; exit 1; }
    exec openclaw logs --follow
    ;;
  *)
    echo "[logs] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2
    exit 1
    ;;
esac

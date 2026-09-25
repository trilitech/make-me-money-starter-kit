#!/usr/bin/env bash
# Make Me Money starter kit — stop.sh
#
# Stops whichever background mode is running, and confirms. Does not touch
# a foreground run in another terminal window — close that window, or press
# Ctrl-C in it, to stop that one.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SESSION="mmm-agent"

[ -f "$ENV_FILE" ] || { echo "[stop] ERROR: .env not found. Run ./setup.sh first." >&2; exit 1; }

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

case "$AGENT" in
  claude)
    if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; then
      tmux kill-session -t "$SESSION"
      echo "[stop] Stopped. Your background Claude agent is no longer running."
    else
      echo "[stop] Nothing was running in the background."
    fi
    ;;
  openclaw)
    command -v openclaw >/dev/null 2>&1 || { echo "[stop] ERROR: openclaw not found on PATH." >&2; exit 1; }
    set +e
    OUT="$(openclaw gateway stop --force 2>&1)"
    RC=$?
    set -e
    if [ "$RC" -ne 0 ]; then
      if printf '%s' "$OUT" | grep -qi 'not installed\|no.*service\|nothing to stop\|no-op'; then
        echo "[stop] Nothing was running in the background."
        exit 0
      fi
      echo "[stop] ERROR: could not stop the background service." >&2
      echo "$OUT" >&2
      exit 1
    fi
    echo "[stop] Stopped. OpenClaw's background service is no longer running."
    ;;
  *)
    echo "[stop] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2
    exit 1
    ;;
esac

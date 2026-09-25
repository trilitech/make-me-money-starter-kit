#!/usr/bin/env bash
# Make Me Money starter kit — status.sh
#
# Plain answer: is your agent running, and where — then its last 15 lines
# of output. Never tells you to attach to tmux.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SESSION="mmm-agent"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/agent.log"
PID_FILE="$LOG_DIR/foreground.pid"

[ -f "$ENV_FILE" ] || { echo "[status] ERROR: .env not found. Run ./setup.sh first." >&2; exit 1; }

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

epoch_to_hhmm() {
  date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo "an earlier time"
}

foreground_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid started
  read -r pid started < "$PID_FILE" 2>/dev/null || return 1
  [ -n "${pid:-}" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

foreground_started_at() {
  local pid started
  read -r pid started < "$PID_FILE"
  epoch_to_hhmm "$started"
}

tmux_session_alive() {
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "$SESSION" 2>/dev/null || return 1
  [ "$(tmux display-message -p -t "$SESSION" '#{pane_dead}')" != "1" ]
}

case "$AGENT" in
  claude)
    if tmux_session_alive; then
      SINCE_EPOCH="$(tmux display-message -p -t "$SESSION" '#{session_created}')"
      echo "Running (background, since $(epoch_to_hhmm "$SINCE_EPOCH"))"
    elif foreground_running; then
      echo "Running in a terminal window (since $(foreground_started_at))"
    else
      echo "Not running"
    fi
    ;;
  openclaw)
    if foreground_running; then
      echo "Running in a terminal window (since $(foreground_started_at))"
    elif command -v openclaw >/dev/null 2>&1 && openclaw gateway status --require-rpc >/dev/null 2>&1; then
      # OpenClaw's own status command confirms the background service is up
      # and answering. We couldn't confirm a documented "started at" field
      # from source/docs, so no since-time here — see the report.
      echo "Running (background)"
    else
      echo "Not running"
    fi
    ;;
  *)
    echo "[status] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2
    exit 1
    ;;
esac

echo
echo "Last output:"
case "$AGENT" in
  claude)
    if tmux_session_alive; then
      if [ -f "$LOG_FILE" ]; then tail -n 15 "$LOG_FILE"; else echo "(no log yet)"; fi
    elif foreground_running; then
      echo "(Claude runs as an interactive terminal app in the foreground; its output isn't saved to a log file there. Look at the window it's running in.)"
    elif [ -f "$LOG_FILE" ]; then
      tail -n 15 "$LOG_FILE"
    else
      echo "(no log yet)"
    fi
    ;;
  openclaw)
    if command -v openclaw >/dev/null 2>&1; then
      openclaw logs --limit 15 --plain 2>/dev/null || echo "(could not fetch logs — is the agent running? see ./start.sh)"
    else
      echo "(openclaw not found on PATH)"
    fi
    ;;
esac

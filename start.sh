#!/usr/bin/env bash
# Make Me Money starter kit — start.sh
#
# Starts the configured engine inside WORKDIR. Uses a tmux session named
# "mmm-agent" when tmux is available, so it survives you closing the
# terminal; otherwise runs in the foreground.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SESSION="mmm-agent"

[ -f "$ENV_FILE" ] || { echo "[start] ERROR: .env not found. Run ./setup.sh first." >&2; exit 1; }

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

: "${WORKDIR:?WORKDIR must be set in .env}"
mkdir -p "$WORKDIR"
ABS_WORKDIR="$(cd "$WORKDIR" && pwd)"

case "$AGENT" in
  claude)
    # --permission-mode auto: a classifier reviews each action instead of a
    # human, so the agent can work unattended. Blocked actions are refused
    # and Claude carries on; nothing waits at the terminal. Needed because
    # DMs are off, so nobody receives the plugin's relayed permission prompts
    # (see README "Permission prompts").
    #
    # If auto mode isn't available to your account, Claude Code starts in
    # Manual instead; the allow list setup.sh writes to
    # $WORKDIR/.claude/settings.json keeps common commands from stalling.
    CMD=(claude --channels "plugin:discord@claude-plugins-official" --permission-mode auto)
    ;;
  openclaw)
    CMD=(openclaw gateway)
    ;;
  *)
    echo "[start] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2
    exit 1
    ;;
esac

# Resolve the binary now, in your own shell, so tmux doesn't pick up a
# different PATH (e.g. another Node version from nvm).
BIN="$(command -v "${CMD[0]}")" || {
  echo "[start] ERROR: ${CMD[0]} not found on PATH. Run ./setup.sh first." >&2
  exit 1
}
CMD[0]="$BIN"

LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/agent.log"
mkdir -p "$LOG_DIR"

echo "[start] Launching: ${CMD[*]}"
echo "[start] Working directory: $ABS_WORKDIR"

# --foreground runs it right here in this terminal: useful to watch it
# start up or see an error. Stop with Ctrl-C.
if [ "${1:-}" = "--foreground" ] || ! command -v tmux >/dev/null 2>&1; then
  command -v tmux >/dev/null 2>&1 || echo "[start] tmux not found, running in the foreground. Closing this terminal stops the agent."
  cd "$ABS_WORKDIR"
  exec "${CMD[@]}"
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [ "$(tmux display-message -p -t "$SESSION" '#{pane_dead}')" = "1" ]; then
    tmux kill-session -t "$SESSION"
  else
    echo "[start] Already running. Watch it with: tmux attach -t $SESSION"
    exit 0
  fi
fi

[ -f "$LOG_FILE" ] && mv "$LOG_FILE" "$LOG_FILE.previous"
QCMD="$(printf '%q ' "${CMD[@]}")"

# Start an idle pane first, set it to stay open if the agent exits and to
# copy everything it prints into logs/agent.log, then launch the agent in
# it. Otherwise a crash closes the session and takes the error with it.
tmux new-session -d -s "$SESSION" -c "$ABS_WORKDIR" -e "PATH=$PATH"
tmux set-option -t "$SESSION" remain-on-exit on >/dev/null
tmux pipe-pane -t "$SESSION" "cat >> $(printf '%q' "$LOG_FILE")"
tmux respawn-pane -k -t "$SESSION" -c "$ABS_WORKDIR" "$QCMD"

echo "[start] Checking it stays up..."
sleep 8
if [ "$(tmux display-message -p -t "$SESSION" '#{pane_dead}')" = "1" ]; then
  CODE="$(tmux display-message -p -t "$SESSION" '#{pane_dead_status}')"
  echo "[start] ERROR: the agent stopped right away (exit code ${CODE:-unknown}). Last output:" >&2
  echo "------" >&2
  tail -n 30 "$LOG_FILE" >&2 || true
  echo "------" >&2
  echo "[start] Full log: $LOG_FILE" >&2
  echo "[start] To watch it start up directly: ./start.sh --foreground" >&2
  tmux kill-session -t "$SESSION"
  exit 1
fi

echo "[start] Running in the background (tmux session '$SESSION')."
echo "[start] Watch it:  tmux attach -t $SESSION   (leave without stopping it: Ctrl-b, then d)"
echo "[start] Log file:  $LOG_FILE"

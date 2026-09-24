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
    # --permission-mode acceptEdits: auto-approves file edits and common
    # filesystem commands in the working directory. Everything else (network
    # calls, unrecognized shell commands, writes outside the working dir)
    # still prompts.
    #
    # That matters here because DMs are off and the channel's allowFrom is
    # empty, so nobody is subscribed to the plugin's permission-prompt relay
    # (see README "Permission prompts" section) — a prompt this mode doesn't
    # clear will sit unanswered until someone is at the terminal. Don't
    # switch to --dangerously-skip-permissions unless your team has decided
    # that's an acceptable risk on your own machine; the README explains why.
    CMD=(claude --channels "plugin:discord@claude-plugins-official" --permission-mode acceptEdits)
    ;;
  openclaw)
    CMD=(openclaw gateway)
    ;;
  *)
    echo "[start] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2
    exit 1
    ;;
esac

echo "[start] Launching: ${CMD[*]}"
echo "[start] Working directory: $ABS_WORKDIR"

if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "[start] tmux session '$SESSION' already running. Attach with: tmux attach -t $SESSION"
    exit 0
  fi
  tmux new-session -d -s "$SESSION" -c "$ABS_WORKDIR" "${CMD[@]}"
  echo "[start] Started in tmux session '$SESSION'."
  echo "[start] Attach with: tmux attach -t $SESSION"
  echo "[start] Detach without stopping it: Ctrl-b then d"
else
  echo "[start] tmux not found — running in the foreground. Install tmux (or screen/pm2) to keep this running after you close the terminal."
  cd "$ABS_WORKDIR"
  exec "${CMD[@]}"
fi

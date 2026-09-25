#!/usr/bin/env bash
# Make Me Money starter kit — start.sh
#
# Runs the configured agent. Default: right here, in this terminal window
# (foreground) — simplest for a laptop, nothing else to manage. Use
# `--background` to keep it running after you close the window: a hidden
# tmux session for Claude, OpenClaw's own background service for OpenClaw.
# `--foreground` is an explicit alias for the default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SESSION="mmm-agent"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/agent.log"
PID_FILE="$LOG_DIR/foreground.pid"

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
mkdir -p "$LOG_DIR"

MODE_ARG="${1:-}"
case "$MODE_ARG" in
  ""|--foreground) MODE=foreground ;;
  --background)    MODE=background ;;
  *)
    echo "[start] ERROR: unknown option '$MODE_ARG'. Use no argument, --foreground, or --background." >&2
    exit 1
    ;;
esac

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

# Resolve the binary now, in your own shell, so tmux (or a background
# service) doesn't pick up a different PATH (e.g. another Node version from
# nvm).
BIN="$(command -v "${CMD[0]}")" || {
  echo "[start] ERROR: ${CMD[0]} not found on PATH. Run ./setup.sh first." >&2
  exit 1
}
CMD[0]="$BIN"

# ---------------------------------------------------------------------------
# Foreground: this terminal window. Default.
# ---------------------------------------------------------------------------
run_foreground() {
  echo "Your agent is running in this window. Keep it open: closing it or pressing Ctrl-C stops your agent. To run it in the background instead, use ./start.sh --background"
  echo "[start] Launching: ${CMD[*]}"
  echo "[start] Working directory: $ABS_WORKDIR"

  # A PID file (not a log file) lets ./status.sh tell "running in a terminal
  # window" apart from "not running", for both agents. We don't delete it on
  # exit: status.sh checks with `kill -0` instead, which is correct whether
  # this process exits cleanly, crashes, or is killed.
  printf '%s %s\n' "$$" "$(date +%s)" > "$PID_FILE"

  cd "$ABS_WORKDIR"

  if [ "$AGENT" = "claude" ]; then
    if [ ! -f "$HOME/.claude.json" ]; then
      echo "[start] NOTE: this looks like Claude Code's first run on this machine. It may ask one-time questions (trust this folder, sign in) — answer them here, in this window."
    fi
    # Claude Code is an interactive TUI and needs a real TTY, so we do not
    # pipe or tee its stdout — that would break the TUI. We deliberately
    # skip file logging for Claude in foreground mode; run
    # ./start.sh --background for a version whose output is saved to
    # logs/agent.log.
    "${CMD[@]}"
  else
    # openclaw gateway just prints plain server logs (not a TUI), so it's
    # safe to also save them to logs/agent.log here.
    "${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
    exit "${PIPESTATUS[0]}"
  fi
}

# ---------------------------------------------------------------------------
# Background: claude — tmux hidden behind the scripts.
# ---------------------------------------------------------------------------
run_background_claude() {
  if ! command -v tmux >/dev/null 2>&1; then
    echo "[start] Claude's background mode uses tmux (you'll never need to use it directly — this kit hides it). It isn't installed." >&2
    if [ "$(uname -s)" = "Darwin" ]; then
      echo "[start] Install it with: brew install tmux" >&2
    else
      echo "[start] Install it with: sudo apt install tmux" >&2
    fi
    echo "[start] Meanwhile, you can run ./start.sh (without --background) and leave the window open." >&2
    exit 1
  fi

  if [ ! -f "$HOME/.claude.json" ]; then
    echo "[start] NOTE: Claude Code's first run on this machine may ask one-time questions (trust this folder, sign in), and nothing is watching this hidden session to answer them." >&2
    echo "[start]       Run ./start.sh once in the foreground first, answer them there, then re-run ./start.sh --background." >&2
  fi

  echo "[start] Launching: ${CMD[*]}"
  echo "[start] Working directory: $ABS_WORKDIR"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    if [ "$(tmux display-message -p -t "$SESSION" '#{pane_dead}')" = "1" ]; then
      tmux kill-session -t "$SESSION"
    else
      echo "[start] Already running in the background. Check it: ./status.sh"
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

  echo "[start] Running in the background."
  echo "[start] Check it:  ./status.sh"
  echo "[start] Watch it:  ./logs.sh"
  echo "[start] Stop it:   ./stop.sh"
}

# ---------------------------------------------------------------------------
# Background: openclaw — its own gateway service (launchd / systemd --user).
# ---------------------------------------------------------------------------
run_background_openclaw() {
  echo "[start] Starting OpenClaw's background service..."

  # `gateway start` is idempotent (already-running is a success, no-op) and
  # is the right first move whether or not the service was installed before.
  # If no managed service is installed yet, OpenClaw itself reports that and
  # exits nonzero (its own "install hints" message) — that's our signal to
  # install instead of just relaying a scary error.
  local out rc
  set +e
  out="$(openclaw gateway start 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'install'; then
      echo "[start] No background service installed yet — installing it now."
      set +e
      out="$(openclaw gateway install 2>&1)"
      rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "[start] ERROR: could not install OpenClaw's background service." >&2
        echo "$out" >&2
        exit 1
      fi
    else
      # Most likely cause: something else — very possibly a plain
      # `./start.sh` foreground gateway — already has the port (18789).
      # Say so plainly instead of just dumping OpenClaw's raw error.
      echo "[start] ERROR: could not start OpenClaw's background service." >&2
      echo "[start] A gateway may already be running elsewhere on the same port — for example, a plain './start.sh' left running in another window." >&2
      echo "[start] Stop it first (Ctrl-C in that window, or ./stop.sh), then try ./start.sh --background again." >&2
      echo "[start] OpenClaw said:" >&2
      echo "$out" >&2
      exit 1
    fi
  fi

  echo "$out"
  echo "[start] Running in the background (OpenClaw's own service)."
  echo "[start] Check it:  ./status.sh"
  echo "[start] Watch it:  ./logs.sh"
  echo "[start] Stop it:   ./stop.sh"
}

run_background() {
  if [ "$AGENT" = "claude" ]; then
    run_background_claude
  else
    run_background_openclaw
  fi
}

case "$MODE" in
  foreground) run_foreground ;;
  background) run_background ;;
esac

#!/usr/bin/env bash
# Make Me Money starter kit — check.sh
#
# Reads back the config setup.sh wrote and prints PASS/FAIL for the safety
# properties we care about: DMs off, only the team channel enabled,
# @mention required, and the allow list matching .env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

[ -f "$ENV_FILE" ] || { echo "[check] ERROR: .env not found." >&2; exit 1; }

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

PASS=1
result() {
  local ok="$1" label="$2"
  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s\n' "$label"
    PASS=0
  fi
}

# JSON reader: prefer jq, fall back to python3, else bail with a clear message.
if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  echo "[check] ERROR: need jq or python3 to parse the config JSON." >&2
  exit 1
fi

jget() { # jget <file> <jq-filter>
  local file="$1" filter="$2"
  if [ "$JSON_TOOL" = jq ]; then
    jq -r "$filter" "$file" 2>/dev/null
  else
    python3 - "$file" "$filter" <<'PY'
import json, re, sys
path, filt = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
# Extremely small filter interpreter for the handful of jq filters this
# script uses: dotted/quoted paths, optionally piped into "| length".
want_length = False
expr = filt
if "|" in expr:
    expr, pipe = expr.split("|", 1)
    want_length = pipe.strip() == "length"
# Pull out each path segment, whether bare (groups, allowFrom, dmPolicy) or
# quoted (a numeric Discord id used as an object key).
segments = [m.group(1) if m.group(1) is not None else m.group(2)
            for m in re.finditer(r'"([^"]*)"|([A-Za-z_][A-Za-z0-9_]*)', expr)]
node = data
for key in segments:
    if isinstance(node, dict):
        node = node.get(key)
    else:
        node = None
    if node is None:
        break
if want_length:
    print(len(node) if isinstance(node, (dict, list)) else 0)
elif isinstance(node, (dict, list)):
    print(json.dumps(node))
elif node is None:
    print("null")
elif isinstance(node, bool):
    print("true" if node else "false")
else:
    print(node)
PY
  fi
}

expected_ids_sorted() {
  IFS=',' read -ra RAW <<< "$MMM_ALLOWED_USER_IDS"
  local ids=()
  for raw in "${RAW[@]}"; do
    id="$(echo "$raw" | xargs)"
    [ -n "$id" ] && ids+=("$id")
  done
  printf '%s\n' "${ids[@]}" | sort
}

check_claude() {
  local STATE_DIR="$HOME/.claude/channels/discord"
  local ACCESS_FILE="$STATE_DIR/access.json"
  local ENV_TOKEN_FILE="$STATE_DIR/.env"

  if [ ! -f "$ACCESS_FILE" ]; then
    echo "[check] ERROR: $ACCESS_FILE does not exist. Run ./setup.sh first." >&2
    exit 1
  fi

  local dm_policy allow_from_len group requiremention group_allow
  dm_policy="$(jget "$ACCESS_FILE" '.dmPolicy')"
  allow_from_len="$(jget "$ACCESS_FILE" '.allowFrom | length' 2>/dev/null || echo "?")"
  requiremention="$(jget "$ACCESS_FILE" ".groups.\"$MMM_CHANNEL_ID\".requireMention")"
  group_allow="$(jget "$ACCESS_FILE" ".groups.\"$MMM_CHANNEL_ID\".allowFrom")"

  # We specifically require "allowlist", not "disabled" — for this plugin,
  # "disabled" also kills guild channel messages (see README "Sources").
  if [ "$dm_policy" = "allowlist" ]; then dm_ok=1; else dm_ok=0; fi
  result "$dm_ok" "DM policy is 'allowlist' (found: $dm_policy)"

  if [ "$allow_from_len" = "0" ]; then dm_empty_ok=1; else dm_empty_ok=0; fi
  result "$dm_empty_ok" "Top-level DM allowFrom is empty (found length: $allow_from_len)"

  if [ -f "$ACCESS_FILE" ]; then
    local group_count
    group_count="$(jget "$ACCESS_FILE" '.groups | length' 2>/dev/null || echo "?")"
    if [ "$group_count" = "1" ]; then groups_ok=1; else groups_ok=0; fi
    result "$groups_ok" "Exactly one channel group is enabled (found: $group_count)"
  fi

  if [ "$requiremention" = "true" ]; then mention_ok=1; else mention_ok=0; fi
  result "$mention_ok" "requireMention is true for channel $MMM_CHANNEL_ID (found: $requiremention)"

  local expected got
  expected="$(expected_ids_sorted)"
  got="$(printf '%s' "$group_allow" | tr -d '[]" \t\r' | tr ',' '\n' | sed '/^$/d' | sort)"
  if [ "$expected" = "$got" ]; then ids_ok=1; else ids_ok=0; fi
  result "$ids_ok" "Channel allow list matches MMM_ALLOWED_USER_IDS"

  if [ -f "$ENV_TOKEN_FILE" ]; then
    local perms
    perms="$(stat -f '%Lp' "$ENV_TOKEN_FILE" 2>/dev/null || stat -c '%a' "$ENV_TOKEN_FILE" 2>/dev/null || echo "?")"
    if [ "$perms" = "600" ]; then tok_ok=1; else tok_ok=0; fi
    result "$tok_ok" "Token file $ENV_TOKEN_FILE is chmod 600 (found: $perms)"
  else
    result 0 "Token file $ENV_TOKEN_FILE exists"
  fi
}

check_openclaw() {
  local CONFIG_FILE="$HOME/.openclaw/openclaw.json"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "[check] ERROR: $CONFIG_FILE does not exist. Run ./setup.sh first." >&2
    exit 1
  fi

  local dm_policy group_policy requiremention chan_enabled users
  dm_policy="$(jget "$CONFIG_FILE" '.channels.discord.dmPolicy')"
  group_policy="$(jget "$CONFIG_FILE" '.channels.discord.groupPolicy')"
  requiremention="$(jget "$CONFIG_FILE" ".channels.discord.guilds.\"$MMM_GUILD_ID\".channels.\"$MMM_CHANNEL_ID\".requireMention")"
  chan_enabled="$(jget "$CONFIG_FILE" ".channels.discord.guilds.\"$MMM_GUILD_ID\".channels.\"$MMM_CHANNEL_ID\".enabled")"
  users="$(jget "$CONFIG_FILE" ".channels.discord.guilds.\"$MMM_GUILD_ID\".channels.\"$MMM_CHANNEL_ID\".users")"

  local plugin_enabled
  plugin_enabled="$(jget "$CONFIG_FILE" '.plugins.entries.discord.enabled')"
  if [ "$plugin_enabled" = "true" ]; then plugin_ok=1; else plugin_ok=0; fi
  result "$plugin_ok" "Discord plugin is trusted: plugins.entries.discord.enabled (found: $plugin_enabled)"

  if [ "$dm_policy" = "disabled" ]; then dm_ok=1; else dm_ok=0; fi
  result "$dm_ok" "dmPolicy is 'disabled' (found: $dm_policy)"

  if [ "$group_policy" = "allowlist" ]; then gp_ok=1; else gp_ok=0; fi
  result "$gp_ok" "groupPolicy is 'allowlist' (found: $group_policy)"

  if [ "$chan_enabled" = "true" ]; then chan_ok=1; else chan_ok=0; fi
  result "$chan_ok" "Team channel $MMM_CHANNEL_ID is enabled (found: $chan_enabled)"

  local chan_count
  chan_count="$(jget "$CONFIG_FILE" ".channels.discord.guilds.\"$MMM_GUILD_ID\".channels | length" 2>/dev/null || echo "?")"
  if [ "$chan_count" = "1" ]; then only_ok=1; else only_ok=0; fi
  result "$only_ok" "Exactly one channel is allowlisted for the guild (found: $chan_count)"

  if [ "$requiremention" = "true" ]; then mention_ok=1; else mention_ok=0; fi
  result "$mention_ok" "requireMention is true for channel $MMM_CHANNEL_ID (found: $requiremention)"

  local expected got
  expected="$(expected_ids_sorted)"
  got="$(printf '%s' "$users" | tr -d '[]" \t\r' | tr ',' '\n' | sed '/^$/d' | sort)"
  if [ "$expected" = "$got" ]; then ids_ok=1; else ids_ok=0; fi
  result "$ids_ok" "Channel allow list matches MMM_ALLOWED_USER_IDS"

  # If the gateway is up, ask it whether Discord is actually connected. The
  # settings above can all pass while the channel still isn't running.
  if command -v openclaw >/dev/null 2>&1 && openclaw gateway status --require-rpc >/dev/null 2>&1; then
    local probe
    probe="$(openclaw channels status --probe 2>&1 | grep -i 'discord' | head -1)"
    if printf '%s' "$probe" | grep -qi 'not-running\|stopped\|blocked'; then
      result 0 "Discord is connected (OpenClaw says: ${probe# *- }). Run ./start.sh --background to restart it."
    elif [ -n "$probe" ]; then
      result 1 "Discord is connected (OpenClaw says: ${probe# *- })"
    fi
  else
    echo "INFO  OpenClaw isn't running yet, so the live Discord connection wasn't checked. Start it, then run ./check.sh again."
  fi
}

check_custom() {
  local VENV="$SCRIPT_DIR/.venv"
  local PY="$VENV/bin/python3"
  [ -x "$PY" ] || PY="$VENV/bin/python"

  local venv_ok=0
  [ -x "$PY" ] && venv_ok=1
  result "$venv_ok" ".venv exists with a python interpreter (found: $PY)"

  local discord_ok=0
  if [ "$venv_ok" -eq 1 ] && "$PY" -c 'import discord' >/dev/null 2>&1; then
    discord_ok=1
  fi
  result "$discord_ok" "discord.py is importable in .venv"

  local have_url=0 have_cmd=0
  [ -n "${CUSTOM_AGENT_URL:-}" ] && have_url=1
  [ -n "${CUSTOM_AGENT_CMD:-}" ] && have_cmd=1
  local target_ok=0
  if [ "$have_url" -eq 1 ] && [ "$have_cmd" -eq 0 ]; then target_ok=1; fi
  if [ "$have_cmd" -eq 1 ] && [ "$have_url" -eq 0 ]; then target_ok=1; fi
  result "$target_ok" "Exactly one of CUSTOM_AGENT_URL / CUSTOM_AGENT_CMD is set (url:$have_url cmd:$have_cmd)"

  if [ "$target_ok" -eq 1 ] && [ "$have_url" -eq 1 ]; then
    # A reachable-but-erroring endpoint (4xx/5xx) still proves something is
    # listening, so treat any HTTP response as PASS; only a connection
    # failure (nothing listening yet) is a FAIL.
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$CUSTOM_AGENT_URL" \
      -H 'Content-Type: application/json' -d '{"prompt":"ping","author_id":"0","author_name":"check.sh","message_id":"0","channel_id":"0"}' \
      --max-time 10 2>/dev/null)" || code=""
    if [ -n "$code" ] && [ "$code" != "000" ]; then
      result 1 "CUSTOM_AGENT_URL answers (got HTTP $code from $CUSTOM_AGENT_URL)"
    else
      result 0 "CUSTOM_AGENT_URL answers (connection refused/unreachable — start your agent first)"
    fi
  elif [ "$target_ok" -eq 1 ] && [ "$have_cmd" -eq 1 ]; then
    echo "INFO  CUSTOM_AGENT_CMD is set; it runs per-prompt, so there's nothing to probe ahead of time."
  fi

  echo "INFO  The channel/mention/DM limits (team channel only, @mention or reply-to-bot required, allowed users only, DMs and bots ignored) are enforced inside bridge/bridge.py's should_handle(), not a separate config file."
}

# Asks Discord about the bot itself, whatever engine runs it. A bot whose
# Message Content Intent is off is refused at login, so it stays offline
# with no error on the agent's side.
check_discord_bot() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "INFO  curl not found, so the Discord bot itself wasn't checked."
    return
  fi
  if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    result 0 "DISCORD_BOT_TOKEN is set in .env"
    return
  fi
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bot $DISCORD_BOT_TOKEN" https://discord.com/api/v10/users/@me 2>/dev/null || echo 000)"
  if [ "$code" = "000" ]; then
    echo "INFO  Couldn't reach Discord, so the bot itself wasn't checked."
    rm -f "$tmp"; return
  fi
  if [ "$code" != "200" ]; then
    result 0 "Discord accepts your bot token (it said HTTP $code: copy the token again from the Bot tab, or click Reset Token)"
    rm -f "$tmp"; return
  fi
  result 1 "Discord accepts your bot token (bot: $(jget "$tmp" '.username'))"

  curl -sS -o "$tmp" -H "Authorization: Bot $DISCORD_BOT_TOKEN" https://discord.com/api/v10/applications/@me 2>/dev/null || true
  local flags
  flags="$(jget "$tmp" '.flags')"
  case "$flags" in ''|null|*[!0-9]*) flags=0 ;; esac
  # GATEWAY_MESSAGE_CONTENT (1<<18) or GATEWAY_MESSAGE_CONTENT_LIMITED (1<<19)
  if [ $(( flags & (262144 | 524288) )) -ne 0 ]; then
    result 1 "Message Content Intent is on"
  else
    result 0 "Message Content Intent is on (turn it on: Developer Portal, Bot tab, Privileged Gateway Intents, then Save and restart your agent)"
  fi

  curl -sS -o "$tmp" -H "Authorization: Bot $DISCORD_BOT_TOKEN" https://discord.com/api/v10/users/@me/guilds 2>/dev/null || true
  if grep -q "\"id\": *\"$MMM_GUILD_ID\"" "$tmp"; then
    result 1 "Your bot is in the Make Me Money server"
  else
    result 0 "Your bot is in the Make Me Money server (not yet: run /agent register in your team channel and wait for an organizer to add it)"
  fi
  rm -f "$tmp"
}

case "${AGENT:-}" in
  claude) check_claude ;;
  openclaw) check_openclaw ;;
  custom) check_custom ;;
  *) echo "[check] ERROR: AGENT must be 'claude', 'openclaw' or 'custom' in .env." >&2; exit 1 ;;
esac
check_discord_bot

echo
if [ "$PASS" -eq 1 ]; then
  echo "[check] All checks passed."
  exit 0
else
  echo "[check] One or more checks FAILED. Re-run ./setup.sh or fix by hand." >&2
  exit 1
fi

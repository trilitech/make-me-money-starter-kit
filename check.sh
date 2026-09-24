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
}

case "${AGENT:-}" in
  claude) check_claude ;;
  openclaw) check_openclaw ;;
  *) echo "[check] ERROR: AGENT must be 'claude' or 'openclaw' in .env." >&2; exit 1 ;;
esac

echo
if [ "$PASS" -eq 1 ]; then
  echo "[check] All checks passed."
  exit 0
else
  echo "[check] One or more checks FAILED. Re-run ./setup.sh or fix by hand." >&2
  exit 1
fi

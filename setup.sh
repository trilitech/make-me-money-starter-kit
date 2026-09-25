#!/usr/bin/env bash
# Make Me Money starter kit — setup.sh
#
# Configures an existing agent (Claude Code's official Discord channel
# plugin, or OpenClaw) so it only talks in your team's Discord channel.
# Does not install a bot of its own. macOS + Linux. Windows: use WSL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
TS="$(date +%Y%m%dT%H%M%S)"

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Load and validate .env
# ---------------------------------------------------------------------------

[ -f "$ENV_FILE" ] || die ".env not found next to setup.sh. Copy .env.example to .env and fill it in first."

# Load .env ourselves instead of `source`-ing it: values can contain commas
# and spaces (e.g. a pasted user-id list) that aren't valid shell syntax, so
# a plain `source` can misparse them. Strips inline "  # comment" trailers
# and optional surrounding quotes; does not otherwise touch the value.
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

require_var() {
  local name="$1"
  local val="${!name:-}"
  [ -n "$val" ] || die "$name is required in .env but is empty."
}

require_var AGENT
require_var DISCORD_BOT_TOKEN
require_var MMM_GUILD_ID
require_var MMM_CHANNEL_ID
require_var MMM_ALLOWED_USER_IDS
require_var MMM_ARENA_URL
require_var WORKDIR

case "$AGENT" in
  claude|openclaw) ;;
  *) die "AGENT must be 'claude' or 'openclaw', got '$AGENT'." ;;
esac

is_digits() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_digits "$MMM_GUILD_ID"   || die "MMM_GUILD_ID must be a numeric Discord id, got '$MMM_GUILD_ID'."
is_digits "$MMM_CHANNEL_ID" || die "MMM_CHANNEL_ID must be a numeric Discord id, got '$MMM_CHANNEL_ID'."

# Split MMM_ALLOWED_USER_IDS on commas, trim whitespace, validate each is digits.
IFS=',' read -ra RAW_USER_IDS <<< "$MMM_ALLOWED_USER_IDS"
USER_IDS=()
for raw in "${RAW_USER_IDS[@]}"; do
  id="$(echo "$raw" | xargs)" # trim
  [ -n "$id" ] || continue
  is_digits "$id" || die "MMM_ALLOWED_USER_IDS contains a non-numeric id: '$id'."
  USER_IDS+=("$id")
done
[ "${#USER_IDS[@]}" -gt 0 ] || die "MMM_ALLOWED_USER_IDS must list at least one teammate Discord user id."

log "Config OK: AGENT=$AGENT, channel=$MMM_CHANNEL_ID, guild=$MMM_GUILD_ID, allowed users=${#USER_IDS[@]}"

# Build a JSON array of user id strings, e.g. ["123","456"]
json_id_array() {
  local out="["
  local first=1
  for id in "$@"; do
    if [ "$first" -eq 1 ]; then first=0; else out+=","; fi
    out+="\"$id\""
  done
  out+="]"
  echo "$out"
}
USER_IDS_JSON="$(json_id_array "${USER_IDS[@]}")"

backup_if_exists() {
  local f="$1"
  if [ -e "$f" ]; then
    cp -p "$f" "${f}.bak.${TS}"
    log "Backed up existing $f -> ${f}.bak.${TS}"
  fi
}

WROTE_SUMMARY=()

# ---------------------------------------------------------------------------
# 2. Engine-specific setup
# ---------------------------------------------------------------------------

setup_claude() {
  command -v claude >/dev/null 2>&1 || die "claude (Claude Code CLI) not found on PATH. Install it: https://code.claude.com/docs/en/quickstart"
  command -v bun >/dev/null 2>&1 || die "bun not found on PATH. The Discord plugin runs on Bun. Install it: curl -fsSL https://bun.sh/install | bash"

  log "claude: $(claude --version 2>/dev/null || echo 'version unknown')"
  log "bun: $(bun --version 2>/dev/null || echo 'version unknown')"

  local STATE_DIR="$HOME/.claude/channels/discord"
  local ENV_TOKEN_FILE="$STATE_DIR/.env"
  local ACCESS_FILE="$STATE_DIR/access.json"

  # --- install the plugin non-interactively where possible ---
  local installed=0
  if claude plugin marketplace add anthropics/claude-plugins-official -y >/dev/null 2>&1; then
    installed=1
  else
    # Marketplace may already be added — that's fine, try install anyway.
    installed=1
  fi
  if [ "$installed" -eq 1 ]; then
    if claude plugin install discord@claude-plugins-official -s user -y >/dev/null 2>&1; then
      log "Installed/updated the discord@claude-plugins-official plugin (user scope)."
    else
      warn "Could not install the plugin non-interactively. Run these once, in a Claude Code session:"
      warn "  /plugin marketplace add anthropics/claude-plugins-official"
      warn "  /plugin install discord@claude-plugins-official"
    fi
  fi

  # --- token file ---
  mkdir -p "$STATE_DIR"
  backup_if_exists "$ENV_TOKEN_FILE"
  printf 'DISCORD_BOT_TOKEN=%s\n' "$DISCORD_BOT_TOKEN" > "$ENV_TOKEN_FILE"
  chmod 600 "$ENV_TOKEN_FILE"
  WROTE_SUMMARY+=("$ENV_TOKEN_FILE (chmod 600)")

  # --- access.json ---
  # dmPolicy "allowlist" with an empty allowFrom drops every DM silently.
  # NOT "disabled" — the plugin's own docs say "disabled" also drops guild
  # channel messages, which would break the one channel we DO want to work.
  backup_if_exists "$ACCESS_FILE"
  cat > "$ACCESS_FILE" <<EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": [],
  "groups": {
    "$MMM_CHANNEL_ID": {
      "requireMention": true,
      "allowFrom": $USER_IDS_JSON
    }
  },
  "pending": {}
}
EOF
  chmod 600 "$ACCESS_FILE"
  WROTE_SUMMARY+=("$ACCESS_FILE (chmod 600)")

  # --- workdir + CLAUDE.md ---
  mkdir -p "$WORKDIR"
  if [ ! -f "$WORKDIR/CLAUDE.md" ]; then
    sed "s|{{MMM_ARENA_URL}}|$MMM_ARENA_URL|g" "$SCRIPT_DIR/templates/CLAUDE.md" > "$WORKDIR/CLAUDE.md"
    WROTE_SUMMARY+=("$WORKDIR/CLAUDE.md (created)")
  else
    log "$WORKDIR/CLAUDE.md already exists — left it alone."
  fi

  # --- $WORKDIR/.claude/settings.json ---
  # Fallback for when auto mode isn't available (start.sh asks for it): an
  # allow list so routine commands don't sit waiting for a terminal approval
  # nobody will give. Written only if absent, so teams can edit it.
  mkdir -p "$WORKDIR/.claude"
  if [ ! -f "$WORKDIR/.claude/settings.json" ]; then
    cat > "$WORKDIR/.claude/settings.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(npm *)", "Bash(npx *)", "Bash(node *)", "Bash(bun *)",
      "Bash(python3 *)", "Bash(pip *)", "Bash(uv *)",
      "Bash(git *)", "Bash(curl *)", "Bash(ls *)", "Bash(cat *)",
      "WebSearch", "WebFetch(domain:*)"
    ],
    "deny": ["Bash(sudo *)", "Bash(rm -rf /*)", "Bash(rm -rf ~*)"]
  }
}
EOF
    WROTE_SUMMARY+=("$WORKDIR/.claude/settings.json (created)")
  else
    log "$WORKDIR/.claude/settings.json already exists — left it alone."
  fi
}

setup_openclaw() {
  command -v openclaw >/dev/null 2>&1 || die "openclaw not found on PATH. Install it: curl -fsSL https://openclaw.ai/install.sh | bash"
  log "openclaw: $(openclaw --version 2>/dev/null || echo 'version unknown')"

  local STATE_DIR="$HOME/.openclaw"
  local CONFIG_FILE="$STATE_DIR/openclaw.json"
  local ENV_TOKEN_FILE="$STATE_DIR/.env"

  mkdir -p "$STATE_DIR"

  command -v node >/dev/null 2>&1 || die "node not found on PATH. OpenClaw needs Node.js 24.16+ anyway: install it, then re-run."
  [ -f "$CONFIG_FILE" ] || log "WARNING: $CONFIG_FILE doesn't exist yet. Run OpenClaw's onboarding first (it starts after install, or run 'openclaw onboard') so your AI model is connected, then re-run this script."

  # ~/.openclaw/.env may hold other keys (e.g. your model provider's API
  # key): replace only the DISCORD_BOT_TOKEN line, keep everything else.
  backup_if_exists "$ENV_TOKEN_FILE"
  local TMP_ENV
  TMP_ENV="$(mktemp)"
  if [ -f "$ENV_TOKEN_FILE" ]; then
    grep -v '^DISCORD_BOT_TOKEN=' "$ENV_TOKEN_FILE" > "$TMP_ENV" || true
  fi
  printf 'DISCORD_BOT_TOKEN=%s\n' "$DISCORD_BOT_TOKEN" >> "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_TOKEN_FILE"
  chmod 600 "$ENV_TOKEN_FILE"
  WROTE_SUMMARY+=("$ENV_TOKEN_FILE (DISCORD_BOT_TOKEN set, other lines kept; chmod 600)")

  # openclaw.json also holds your model/provider settings from onboarding,
  # so replace ONLY channels.discord and keep the rest of the file.
  #
  # dmPolicy "disabled" turns off DMs outright (OpenClaw scopes DM and guild
  # policy separately, so this does not touch the guild/channel allowlist
  # below — unlike the Claude plugin's "disabled", these are independent).
  # groupPolicy "allowlist" + a channels map with only our channel means
  # every other channel in the guild is denied by default.
  local DISCORD_BLOCK
  DISCORD_BLOCK=$(cat <<EOF
{
  "enabled": true,
  "token": { "source": "env", "provider": "default", "id": "DISCORD_BOT_TOKEN" },
  "dmPolicy": "disabled",
  "groupPolicy": "allowlist",
  "guilds": {
    "$MMM_GUILD_ID": {
      "requireMention": true,
      "users": $USER_IDS_JSON,
      "channels": {
        "$MMM_CHANNEL_ID": {
          "enabled": true,
          "requireMention": true,
          "users": $USER_IDS_JSON
        }
      }
    }
  }
}
EOF
)
  backup_if_exists "$CONFIG_FILE"
  # openclaw.json is JSON5. Plain JSON (what onboarding normally writes)
  # merges automatically; a file with comments or trailing commas can't be
  # rewritten safely, so we stop and print the block to paste by hand.
  if ! DISCORD_BLOCK="$DISCORD_BLOCK" node -e '
    const fs = require("fs");
    const file = process.argv[1];
    let cfg = {};
    if (fs.existsSync(file)) {
      try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); }
      catch { process.exit(3); }
    }
    cfg.channels = cfg.channels || {};
    cfg.channels.discord = JSON.parse(process.env.DISCORD_BLOCK);
    // OpenClaw ships Discord as a plugin and only runs it once it is
    // trusted explicitly. Without this the channel shows "configured,
    // stopped, health:not-running". (No apostrophes in this block: it sits
    // inside a single-quoted shell string.)
    cfg.plugins = cfg.plugins || {};
    cfg.plugins.entries = cfg.plugins.entries || {};
    cfg.plugins.entries.discord = Object.assign({}, cfg.plugins.entries.discord, { enabled: true });
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  ' "$CONFIG_FILE"; then
    echo "[setup] ERROR: $CONFIG_FILE has comments or other JSON5 syntax, so it can't be merged automatically." >&2
    echo "[setup] Set channels.discord in that file to exactly this:" >&2
    echo "$DISCORD_BLOCK" >&2
    echo "[setup] Also add this, so OpenClaw trusts its Discord plugin, then run ./check.sh:" >&2
    echo '  "plugins": { "entries": { "discord": { "enabled": true } } }' >&2
    exit 1
  fi
  chmod 600 "$CONFIG_FILE"
  WROTE_SUMMARY+=("$CONFIG_FILE (channels.discord set, rest of file kept; chmod 600)")

  mkdir -p "$WORKDIR"
  if [ ! -f "$WORKDIR/AGENTS.md" ]; then
    sed "s|{{MMM_ARENA_URL}}|$MMM_ARENA_URL|g" "$SCRIPT_DIR/templates/AGENTS.md" > "$WORKDIR/AGENTS.md"
    WROTE_SUMMARY+=("$WORKDIR/AGENTS.md (created)")
  else
    log "$WORKDIR/AGENTS.md already exists — left it alone."
  fi
}

if [ "$AGENT" = "claude" ]; then
  setup_claude
else
  setup_openclaw
fi

# ---------------------------------------------------------------------------
# 3. Summary
# ---------------------------------------------------------------------------

log "Done. Files written or updated:"
for line in "${WROTE_SUMMARY[@]}"; do
  printf '  - %s\n' "$line"
done
log "Next:"
log "  ./check.sh              verify the config is safe"
log "  ./start.sh              run your agent — leave this window open"
log "  ./start.sh --background keep it running after you close the window"
log "  ./status.sh             is it running, and where"
log "  ./logs.sh               watch its output live"
log "  ./stop.sh               stop a background run"

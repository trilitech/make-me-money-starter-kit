# Make Me Money — starter kit

This configures an agent you already have — Claude Code, or OpenClaw — so it
only talks in your team's private Discord channel. It is not a new bot and it
does not write any bot logic. It writes a few config files that the agent
software already reads, then starts it.

Event: "Make Me Money", 2–21 Nov 2026.

## 1. What this is

Two bots sit in your team channel:

- **MMM Bot** (ours) — the organizer bot. It logs every prompt sent to your
  agent so we can see what happened.
- **Your agent's bot** — a Discord bot you create, wired to your own agent
  (Claude Code or OpenClaw), running on your own machine, on your own
  subscription or API key.

```
  you / teammates            MMM Bot                 your agent's bot
        |                       |                            |
        |--- @mention/reply --->|--- logs the prompt -------->|
        |                       |                       (only if @mentioned
        |<---------- reply from your agent's bot -------------|  or replied to)
```

Only messages that @mention your agent's bot, or reply to one of its own
messages, reach the agent. Everything else in the channel is ignored by
design — the setup below enforces that.

## 2. The rules

- Everything goes through your team channel. No DMs to the agent.
- Nobody types directly into the agent's terminal to give it instructions.
- No second agent working the problem outside the logged channel.
- We can only log what happens in the channel — the rest is on trust and the
  daily attestation.

## 3. Create the Discord bot

1. Go to the [Discord Developer Portal](https://discord.com/developers/applications)
   → **New Application** → name it (e.g. `TeamName Agent`).
2. Copy the **Application ID** from **General Information** — this is your
   `client_id`.
3. Go to **Bot** → **Reset Token** → copy the token immediately (Discord only
   shows it once). Never paste it into chat, a repo, or a screenshot.
4. Still on **Bot**, under **Privileged Gateway Intents**, enable **Message
   Content Intent**. Without it your bot receives messages with empty text.
5. In your team channel, run:
   ```
   /agent register client_id:<your application id>
   ```
   An organizer then invites your bot with no server-wide permissions and
   grants it access to your team channel only.

   **Registration is final.** Running it again just tells you it's already
   locked. If you registered the wrong bot, ask an organizer to run
   `/agent reset` before you try again.

## 4. Get your `.env` block

In your team channel, run:

```
/agent config
```

MMM Bot replies to you privately with a ready-made `.env` block (the guild
id, channel id, your teammates' user ids, and your arena URL already filled
in). Copy `.env.example` to `.env`, paste that block in, and add your bot
token from step 3:

```bash
cp .env.example .env
# then edit .env
```

`.env` fields:

| Variable | Meaning |
| --- | --- |
| `AGENT` | `claude` or `openclaw` |
| `DISCORD_BOT_TOKEN` | your agent bot's token — keep secret |
| `MMM_GUILD_ID` | your Discord server id |
| `MMM_CHANNEL_ID` | your team channel id |
| `MMM_ALLOWED_USER_IDS` | comma-separated teammate Discord user ids |
| `MMM_ARENA_URL` | your team's arena post URL — keep secret |
| `WORKDIR` | folder the agent works in (default `./workspace`) |

## 5. Run it

```bash
./setup.sh
./check.sh
./start.sh
```

`setup.sh` validates `.env`, installs/configures the plugin (Claude) or the
config (OpenClaw), and writes a brief (`CLAUDE.md` or `AGENTS.md`) into
`WORKDIR` with the event goal and the arena command. `check.sh` reads the
config back and prints PASS/FAIL for the safety properties that matter: DMs
off, only your team channel enabled, @mention required, and the allow list
matching your `.env`. `start.sh` launches the agent, in a `tmux` session
named `mmm-agent` when tmux is installed.

## 6. Keep it running 24/7

The agent only responds while its process is running.

- Simplest: leave your laptop awake for the two weeks (disable sleep, stay
  plugged in and on Wi-Fi).
- More reliable: a small always-on VPS ($5–10/month), with `tmux` (which
  `start.sh` already uses if installed), `pm2`, or `systemd` so it survives
  disconnects and reboots.

If you used `start.sh`'s tmux session, reattach any time with
`tmux attach -t mmm-agent`, and detach without stopping it with `Ctrl-b`
then `d`.

## 7. Test it

1. In your team channel, @mention your agent's bot (or reply to one of its
   messages). It should respond.
2. Send a plain message in the same channel, without mentioning it. It
   should be ignored — no reply, no reaction.

If step 2 fails, something is misconfigured; re-run `./check.sh`.

## 8. Troubleshooting

- **Nothing responds at all** — is the process still running? Check
  `tmux attach -t mmm-agent` (Claude/OpenClaw) or your process manager.
  Confirm Message Content Intent is enabled on the bot (step 3.4).
- **It responds without being @mentioned** — `check.sh` will show
  `requireMention` as `false` or missing; re-run `./setup.sh`.
- **It responds in the wrong channel, or DMs work** — re-run `./check.sh`.
  If it still fails, check for a hand-edited `access.json` (Claude) or
  `openclaw.json` (OpenClaw) that setup.sh didn't fully overwrite; delete the
  `.bak.*` backup only once you've confirmed the new file is correct.
- **Permission prompts** — see the dedicated section below. This is the
  most likely thing to trip up an unattended run.
- **Plugin/marketplace install failed (Claude)** — `setup.sh` prints the
  exact `/plugin marketplace add ...` and `/plugin install ...` commands to
  run by hand inside a `claude` session if the non-interactive install
  didn't work.
- **OpenClaw workspace files** — OpenClaw's own long-term workspace lives at
  `~/.openclaw/workspace` by default; if your OpenClaw install expects
  `AGENTS.md` there rather than in this kit's `WORKDIR`, copy
  `templates/AGENTS.md` there too. (unverified — we did not confirm this
  from source; OpenClaw's install/workspace wiring differs by install
  method.)

### Permission prompts (read this)

Claude Code (and OpenClaw) can pause mid-task to ask permission before
running a tool — editing a file outside the working directory, running an
unfamiliar shell command, and so on.

For the Claude Discord plugin specifically, we confirmed from its source
(`server.ts` in `anthropics/claude-plugins-official`) that a permission
prompt is only relayed into Discord as a DM to users in the plugin's
`allowFrom` list. This kit intentionally keeps `allowFrom` empty (see
"Rules" and the setup below) so nobody can DM the agent — which also means
**nobody receives that relayed prompt**. If Claude hits a permission prompt
with no one at the terminal to answer it, the session just pauses. It does
not crash; it does not skip the step; it waits.

`start.sh` starts Claude in **auto mode** (`--permission-mode auto`). A
second model reviews each action instead of a person. Routine work runs,
risky actions are refused, and Claude carries on either way, so nothing
waits at the terminal. Auto mode is the default on Pro, Max and Team plans
and is available with an Anthropic API key
([docs](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode)).

If auto mode isn't available to your account, Claude Code starts in Manual
mode instead. As a backup, `setup.sh` writes `workspace/.claude/settings.json`
with an allow list of common commands (npm, node, git, curl, python and so
on) so those still run without a prompt. Edit that file to add the tools
your agent uses. Anything not on the list will pause until someone
approves it at the terminal.

We deliberately do **not** default to `--dangerously-skip-permissions`. If
your team decides you want a fully unattended run and understands the
risk — it runs on your own machine, under your own account, and even in
that mode a fixed list of especially dangerous actions still gets denied
rather than approved (see Claude Code's permission-modes docs) — that's your
call to make and your risk to carry, not something this kit turns on by
default.

## Sources

Confirmed from source (not just doc pages) for this kit's design:

- `~/.claude/channels/discord/access.json` schema (`dmPolicy`, `allowFrom`,
  `groups.<channelId>.{requireMention,allowFrom}`), and that the server
  re-reads it on every inbound message (not just at startup) — from
  [`server.ts`](https://github.com/anthropics/claude-plugins-official/blob/main/external_plugins/discord/server.ts)
  and [`ACCESS.md`](https://github.com/anthropics/claude-plugins-official/blob/main/external_plugins/discord/ACCESS.md)
  in `anthropics/claude-plugins-official`.
- `dmPolicy: "disabled"` also drops guild/group channel messages for this
  plugin (confirmed in `server.ts`: the `disabled` check runs before the
  DM/guild branch) — hence this kit uses `"allowlist"` with an empty
  `allowFrom` instead.
- The permission-prompt relay only DMs users in `allowFrom` — confirmed in
  `server.ts`'s `permission_request` notification handler, which iterates
  `access.allowFrom`.
- `claude plugin marketplace add <source>` and `claude plugin install
  <plugin> -s <scope> -y` are real non-interactive CLI subcommands (not only
  `/plugin` slash commands run inside a session) — confirmed in
  [Plugins reference](https://code.claude.com/docs/en/plugins-reference) and
  [Plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces).
- Permission-mode behavior (`auto`, `bypassPermissions`/
  `--dangerously-skip-permissions`, and the fixed list of actions no mode
  auto-approves) — confirmed in
  [Choose a permission mode](https://code.claude.com/docs/en/permission-modes).
- Channels behavior: a channel plugin declaring the permission-relay
  capability can forward prompts remotely, but "If Claude hits a permission
  prompt while you're away from the terminal, the session pauses until you
  respond" — confirmed in [Channels](https://code.claude.com/docs/en/channels).
- OpenClaw's Discord config schema (`channels.discord.{dmPolicy, allowFrom,
  groupPolicy, guilds.<id>.{requireMention, users, channels.<id>}}`) — from
  [`src/config/types.discord.ts`](https://github.com/openclaw/openclaw/blob/main/src/config/types.discord.ts)
  in `openclaw/openclaw`, cross-checked against
  [`docs/channels/discord/access-control.md`](https://github.com/openclaw/openclaw/blob/main/docs/channels/discord/access-control.md).
  Note: for OpenClaw, `dmPolicy` and `groupPolicy` are independent — unlike
  the Claude plugin, `dmPolicy: "disabled"` does not affect guild channels.
- OpenClaw's config file location (`~/.openclaw/openclaw.json`) and install
  command (`curl -fsSL https://openclaw.ai/install.sh | bash`) — from
  [`docs/start/setup.md`](https://github.com/openclaw/openclaw/blob/main/docs/start/setup.md)
  and
  [`docs/start/getting-started.md`](https://github.com/openclaw/openclaw/blob/main/docs/start/getting-started.md).

(unverified) items are marked inline above, in setup.sh comments, and in
Troubleshooting.

#!/usr/bin/env python3
"""Make Me Money starter kit — bridge.py

A small Discord relay for teams running their own agent (anything OpenClaw
can't run: OpenAI Agents SDK, LangGraph, custom Python, and so on). It
applies the same channel/mention/DM limits as the kit's Claude and OpenClaw
paths, then hands each prompt to your agent one of two ways, set in the
kit's .env:

  CUSTOM_AGENT_URL=http://localhost:8000/prompt
      POSTs JSON {"prompt", "author_id", "author_name", "message_id",
      "channel_id"}. Expects JSON {"reply": "..."} back, or plain text.

  CUSTOM_AGENT_CMD="python my_agent.py"
      Runs the command with the prompt on stdin and the same fields as
      env vars (MMM_PROMPT_AUTHOR_ID, MMM_PROMPT_AUTHOR_NAME,
      MMM_PROMPT_MESSAGE_ID, MMM_PROMPT_CHANNEL_ID). Its stdout is the
      reply.

Exactly one of the two must be set. Timeout: CUSTOM_AGENT_TIMEOUT, seconds,
default 900.

Python 3.9+. Reads the kit's .env itself (a small parser below — no
python-dotenv needed). discord.py is imported lazily/guarded so
`should_handle` and `split_reply` stay importable and unit-testable
without discord.py installed (see test_bridge.py).
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import subprocess
import sys
import traceback
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

try:
    import discord  # type: ignore
except ImportError:  # pragma: no cover - exercised by test_bridge.py
    discord = None  # type: ignore

KIT_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = KIT_DIR / ".env"

DEFAULT_TIMEOUT = 900


# ---------------------------------------------------------------------------
# .env parsing (plain functions, no discord/python-dotenv dependency)
# ---------------------------------------------------------------------------


def parse_env_text(text: str) -> dict:
    """Parse a kit .env file's contents into a dict.

    Mirrors the bash `load_env_file` used by setup.sh/check.sh/start.sh:
    strips inline "  # comment" trailers and optional surrounding quotes,
    skips blank lines and full-line comments, otherwise leaves the value
    untouched (values may contain commas, spaces, URLs, etc).
    """
    out: dict = {}
    for raw_line in text.splitlines():
        line = re.sub(r"[ \t]+#.*$", "", raw_line)
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        out[key] = val
    return out


def load_env(path: Path) -> dict:
    """Load the kit's .env, layered over the current process environment
    (the .env file wins, matching the bash scripts' `export`)."""
    combined = dict(os.environ)
    if path.is_file():
        combined.update(parse_env_text(path.read_text(encoding="utf-8")))
    return combined


def validate_custom_agent_target(url: Optional[str], cmd: Optional[str]) -> None:
    """Raise ValueError unless exactly one of url/cmd is a non-empty value."""
    have_url = bool(url and url.strip())
    have_cmd = bool(cmd and cmd.strip())
    if have_url and have_cmd:
        raise ValueError(
            "both CUSTOM_AGENT_URL and CUSTOM_AGENT_CMD are set in .env — set exactly one."
        )
    if not have_url and not have_cmd:
        raise ValueError(
            "neither CUSTOM_AGENT_URL nor CUSTOM_AGENT_CMD is set in .env — set exactly one."
        )


# ---------------------------------------------------------------------------
# Plain, discord-free logic: filtering and reply splitting
# ---------------------------------------------------------------------------


def should_handle(
    *,
    is_dm: bool,
    author_id: int,
    author_is_bot: bool,
    channel_id: int,
    allowed_channel_id: int,
    allowed_user_ids: set,
    mentions_bot: bool,
    is_reply_to_bot: bool,
) -> bool:
    """The single gate a message must pass to be handed to the agent:
    not a DM, not from a bot (including this one), in the team channel,
    from an allowed teammate, and either @mentions the bot or replies to
    one of the bot's own messages."""
    if is_dm:
        return False
    if author_is_bot:
        return False
    if channel_id != allowed_channel_id:
        return False
    if author_id not in allowed_user_ids:
        return False
    if not (mentions_bot or is_reply_to_bot):
        return False
    return True


def split_reply(text: str, limit: int = 2000) -> list:
    """Split text into chunks of at most `limit` characters, breaking on
    the last newline (or else the last space) before the limit when one
    is available, so words/lines aren't cut mid-way unless unavoidable.
    Always returns at least one (possibly empty) chunk."""
    if text == "":
        return [""]
    chunks = []
    remaining = text
    while remaining:
        if len(remaining) <= limit:
            chunks.append(remaining)
            break
        window = remaining[:limit]
        cut = window.rfind("\n")
        if cut <= 0:
            cut = window.rfind(" ")
        if cut <= 0:
            cut = limit
        chunks.append(remaining[:cut])
        remaining = remaining[cut:]
        # Don't let a leading space/newline start the next chunk.
        remaining = remaining.lstrip(" \n")
    return chunks


def strip_bot_mention(text: str, bot_id: int) -> str:
    """Remove `<@bot_id>` / `<@!bot_id>` mention tokens for the bot and
    trim the result."""
    pattern = re.compile(r"<@!?%d>" % bot_id)
    return pattern.sub("", text).strip()


def format_agent_error(exc: BaseException) -> str:
    """Short, user-facing summary for a reply. Full details go to the log."""
    return "Your agent returned an error: %s: %s" % (type(exc).__name__, exc)


def log_line(*parts) -> str:
    text = " ".join(str(p) for p in parts)
    print(text, flush=True)
    return text


# ---------------------------------------------------------------------------
# Calling the team's agent
# ---------------------------------------------------------------------------


def _call_agent_url_sync(url: str, payload: dict, timeout: int) -> str:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        return body
    if isinstance(parsed, dict) and "reply" in parsed:
        return str(parsed["reply"])
    return body


def _call_agent_cmd_sync(
    cmd: str,
    prompt: str,
    author_id,
    author_name: str,
    message_id,
    channel_id,
    timeout: int,
) -> str:
    env = os.environ.copy()
    env["MMM_PROMPT_AUTHOR_ID"] = str(author_id)
    env["MMM_PROMPT_AUTHOR_NAME"] = str(author_name)
    env["MMM_PROMPT_MESSAGE_ID"] = str(message_id)
    env["MMM_PROMPT_CHANNEL_ID"] = str(channel_id)
    proc = subprocess.run(
        cmd,
        shell=True,
        input=prompt,
        capture_output=True,
        text=True,
        env=env,
        timeout=timeout,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip()[:500]
        raise RuntimeError(
            "command exited %d%s" % (proc.returncode, f": {detail}" if detail else "")
        )
    return proc.stdout


async def call_agent(
    *,
    url: Optional[str],
    cmd: Optional[str],
    timeout: int,
    prompt: str,
    author_id,
    author_name: str,
    message_id,
    channel_id,
) -> str:
    if url:
        payload = {
            "prompt": prompt,
            "author_id": str(author_id),
            "author_name": str(author_name),
            "message_id": str(message_id),
            "channel_id": str(channel_id),
        }
        return await asyncio.to_thread(_call_agent_url_sync, url, payload, timeout)
    return await asyncio.to_thread(
        _call_agent_cmd_sync,
        cmd,
        prompt,
        author_id,
        author_name,
        message_id,
        channel_id,
        timeout,
    )


# ---------------------------------------------------------------------------
# Discord bot
# ---------------------------------------------------------------------------


def build_client(config: dict):
    """Build the discord.Client. Kept separate from module import so this
    file stays importable (for should_handle/split_reply tests) even
    without discord.py installed."""
    if discord is None:
        raise RuntimeError(
            "discord.py is not installed. Run ./setup.sh, or: "
            "pip install -r bridge/requirements.txt"
        )

    intents = discord.Intents.default()
    intents.message_content = True
    client = discord.Client(intents=intents)

    allowed_channel_id = int(config["MMM_CHANNEL_ID"])
    allowed_user_ids = config["_allowed_user_ids"]
    custom_url = config.get("CUSTOM_AGENT_URL") or None
    custom_cmd = config.get("CUSTOM_AGENT_CMD") or None
    timeout = config["_timeout"]

    async def is_reply_to_bot(message) -> bool:
        ref = message.reference
        if ref is None:
            return False
        resolved = ref.resolved
        if resolved is None or isinstance(resolved, discord.DeletedReferencedMessage):
            try:
                resolved = await message.channel.fetch_message(ref.message_id)
            except discord.HTTPException:
                return False
        return getattr(resolved, "author", None) is not None and resolved.author.id == client.user.id

    async def handle_prompt(message) -> None:
        prompt = strip_bot_mention(message.content, client.user.id)
        try:
            await message.add_reaction("👀")
        except discord.HTTPException:
            pass  # a missing reaction permission shouldn't stop the reply

        try:
            async with message.channel.typing():
                reply_text = await call_agent(
                    url=custom_url,
                    cmd=custom_cmd,
                    timeout=timeout,
                    prompt=prompt,
                    author_id=message.author.id,
                    author_name=str(message.author),
                    message_id=message.id,
                    channel_id=message.channel.id,
                )
        except Exception as exc:  # noqa: BLE001 - never crash the bridge
            log_line(
                "[bridge] ERROR handling prompt from",
                message.author.id,
                "in channel",
                message.channel.id,
                "message",
                message.id,
                "-",
                type(exc).__name__,
                exc,
            )
            traceback.print_exc()
            try:
                await message.reply(format_agent_error(exc)[:2000])
            except discord.HTTPException:
                pass
            return

        text = reply_text if reply_text and reply_text.strip() else "(your agent returned an empty reply)"
        chunks = split_reply(text)
        try:
            await message.reply(chunks[0])
            for chunk in chunks[1:]:
                await message.channel.send(chunk)
        except discord.HTTPException as exc:
            log_line("[bridge] ERROR sending reply to", message.channel.id, "-", exc)
            return

        log_line(
            "[bridge] handled prompt from",
            message.author.id,
            "in channel",
            message.channel.id,
            "message",
            message.id,
            "- ok,",
            len(text),
            "chars,",
            len(chunks),
            "chunk(s)",
        )

    @client.event
    async def on_ready():
        log_line("[bridge] logged in as", client.user, f"(id {client.user.id})" if client.user else "")
        log_line(
            "[bridge] INFO channel/mention/DM limits are enforced in this bridge (see should_handle in bridge.py);",
            "no separate config file to check.",
        )

    @client.event
    async def on_message(message):
        try:
            if client.user is not None and message.author.id == client.user.id:
                return
            is_dm = message.guild is None
            author_is_bot = bool(message.author.bot)
            channel_id = message.channel.id if not is_dm else -1

            mentions_bot = False
            reply_to_bot = False
            cheap_ok = (
                not is_dm
                and not author_is_bot
                and channel_id == allowed_channel_id
                and message.author.id in allowed_user_ids
                and client.user is not None
            )
            if cheap_ok:
                mentions_bot = client.user in message.mentions
                if not mentions_bot:
                    reply_to_bot = await is_reply_to_bot(message)

            if not should_handle(
                is_dm=is_dm,
                author_id=message.author.id,
                author_is_bot=author_is_bot,
                channel_id=channel_id,
                allowed_channel_id=allowed_channel_id,
                allowed_user_ids=allowed_user_ids,
                mentions_bot=mentions_bot,
                is_reply_to_bot=reply_to_bot,
            ):
                return

            await handle_prompt(message)
        except Exception:  # noqa: BLE001 - one bad prompt must never crash the bridge
            traceback.print_exc()

    return client


def build_config() -> dict:
    env = load_env(ENV_FILE)

    def require(name: str) -> str:
        val = env.get(name, "")
        if not val:
            raise SystemExit(
                "[bridge] ERROR: %s is required in .env but is empty." % name
            )
        return val

    require("DISCORD_BOT_TOKEN")
    require("MMM_CHANNEL_ID")
    require("MMM_ALLOWED_USER_IDS")

    custom_url = env.get("CUSTOM_AGENT_URL", "").strip()
    custom_cmd = env.get("CUSTOM_AGENT_CMD", "").strip()
    try:
        validate_custom_agent_target(custom_url, custom_cmd)
    except ValueError as exc:
        raise SystemExit("[bridge] ERROR: %s" % exc)

    try:
        timeout = int(env.get("CUSTOM_AGENT_TIMEOUT", "") or DEFAULT_TIMEOUT)
    except ValueError:
        raise SystemExit("[bridge] ERROR: CUSTOM_AGENT_TIMEOUT must be a number of seconds.")

    allowed_user_ids = set()
    for raw in env["MMM_ALLOWED_USER_IDS"].split(","):
        raw = raw.strip()
        if not raw:
            continue
        if not raw.isdigit():
            raise SystemExit(
                "[bridge] ERROR: MMM_ALLOWED_USER_IDS contains a non-numeric id: '%s'." % raw
            )
        allowed_user_ids.add(int(raw))
    if not allowed_user_ids:
        raise SystemExit(
            "[bridge] ERROR: MMM_ALLOWED_USER_IDS must list at least one teammate Discord user id."
        )

    if not env["MMM_CHANNEL_ID"].isdigit():
        raise SystemExit(
            "[bridge] ERROR: MMM_CHANNEL_ID must be a numeric Discord id, got '%s'."
            % env["MMM_CHANNEL_ID"]
        )

    config = dict(env)
    config["CUSTOM_AGENT_URL"] = custom_url
    config["CUSTOM_AGENT_CMD"] = custom_cmd
    config["_allowed_user_ids"] = allowed_user_ids
    config["_timeout"] = timeout
    return config


def main() -> None:
    if discord is None:
        raise SystemExit(
            "[bridge] ERROR: discord.py is not installed. Run ./setup.sh, or: "
            "pip install -r bridge/requirements.txt"
        )
    config = build_config()
    log_line(
        "[bridge] starting: channel",
        config["MMM_CHANNEL_ID"],
        "allowed users",
        len(config["_allowed_user_ids"]),
        "target",
        "URL " + config["CUSTOM_AGENT_URL"] if config["CUSTOM_AGENT_URL"] else "CMD",
        "timeout",
        config["_timeout"],
        "s",
    )
    client = build_client(config)
    client.run(config["DISCORD_BOT_TOKEN"])


if __name__ == "__main__":
    main()

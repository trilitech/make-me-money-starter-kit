#!/usr/bin/env python3
"""Unit tests for the discord-free parts of bridge.py.

Run with: python3 -m unittest bridge.test_bridge -v   (from the kit root)
      or: python3 -m unittest discover -s bridge -v
Deliberately does not require discord.py to be installed — bridge.py
guards that import, and this file only exercises plain functions.
"""

import importlib.util
import unittest
from pathlib import Path

# Load bridge.py directly by file path rather than `import bridge`: when this
# file runs as `python3 -m unittest bridge.test_bridge` from the kit root,
# the bare name "bridge" resolves to the bridge/ directory itself (a
# namespace package), not bridge/bridge.py — this sidesteps that collision
# and works the same whether invoked from the kit root or from bridge/.
_BRIDGE_PY = Path(__file__).resolve().parent / "bridge.py"
_spec = importlib.util.spec_from_file_location("mmm_bridge_under_test", _BRIDGE_PY)
bridge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bridge)  # noqa: E402


class ShouldHandleTests(unittest.TestCase):
    def base_kwargs(self, **overrides):
        kwargs = dict(
            is_dm=False,
            author_id=111,
            author_is_bot=False,
            channel_id=999,
            allowed_channel_id=999,
            allowed_user_ids={111, 222},
            mentions_bot=True,
            is_reply_to_bot=False,
        )
        kwargs.update(overrides)
        return kwargs

    def test_accepts_mention_from_allowed_user_in_channel(self):
        self.assertTrue(bridge.should_handle(**self.base_kwargs()))

    def test_accepts_reply_to_bot_without_mention(self):
        self.assertTrue(
            bridge.should_handle(
                **self.base_kwargs(mentions_bot=False, is_reply_to_bot=True)
            )
        )

    def test_rejects_dm(self):
        self.assertFalse(bridge.should_handle(**self.base_kwargs(is_dm=True)))

    def test_rejects_bot_author(self):
        self.assertFalse(bridge.should_handle(**self.base_kwargs(author_is_bot=True)))

    def test_rejects_wrong_channel(self):
        self.assertFalse(bridge.should_handle(**self.base_kwargs(channel_id=1)))

    def test_rejects_user_not_allowed(self):
        self.assertFalse(bridge.should_handle(**self.base_kwargs(author_id=333)))

    def test_rejects_no_mention_and_no_reply(self):
        self.assertFalse(
            bridge.should_handle(
                **self.base_kwargs(mentions_bot=False, is_reply_to_bot=False)
            )
        )


class SplitReplyTests(unittest.TestCase):
    def test_short_text_single_chunk(self):
        self.assertEqual(bridge.split_reply("hello"), ["hello"])

    def test_empty_text_single_empty_chunk(self):
        self.assertEqual(bridge.split_reply(""), [""])

    def test_exact_limit_single_chunk(self):
        text = "a" * 2000
        chunks = bridge.split_reply(text, limit=2000)
        self.assertEqual(chunks, [text])

    def test_over_limit_splits_into_multiple_chunks(self):
        text = "a" * 2500
        chunks = bridge.split_reply(text, limit=2000)
        self.assertEqual(len(chunks), 2)
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 2000)
        self.assertEqual("".join(chunks), text)

    def test_all_chunks_within_limit_for_long_text(self):
        text = "word " * 1000  # 5000 chars, with spaces to break on
        chunks = bridge.split_reply(text, limit=2000)
        self.assertGreater(len(chunks), 1)
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 2000)
            self.assertNotEqual(chunk, "")

    def test_prefers_breaking_on_newline(self):
        text = ("line" * 100 + "\n") * 20  # long lines separated by newlines
        chunks = bridge.split_reply(text, limit=500)
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 500)

    def test_no_break_point_hard_cuts(self):
        text = "a" * 4001
        chunks = bridge.split_reply(text, limit=2000)
        self.assertEqual(len(chunks), 3)
        for chunk in chunks:
            self.assertLessEqual(len(chunk), 2000)


class StripBotMentionTests(unittest.TestCase):
    def test_strips_plain_mention(self):
        self.assertEqual(bridge.strip_bot_mention("<@123> hello", 123), "hello")

    def test_strips_nickname_mention(self):
        self.assertEqual(bridge.strip_bot_mention("<@!123> hello there", 123), "hello there")

    def test_leaves_other_mentions_alone(self):
        self.assertEqual(
            bridge.strip_bot_mention("<@123> hi <@456>", 123), "hi <@456>"
        )

    def test_no_mention_present(self):
        self.assertEqual(bridge.strip_bot_mention("just text", 123), "just text")


class ParseEnvTests(unittest.TestCase):
    def test_parses_basic_pairs(self):
        text = "FOO=bar\nBAZ=1\n"
        self.assertEqual(bridge.parse_env_text(text), {"FOO": "bar", "BAZ": "1"})

    def test_skips_comments_and_blank_lines(self):
        text = "# a comment\n\nFOO=bar\n"
        self.assertEqual(bridge.parse_env_text(text), {"FOO": "bar"})

    def test_strips_inline_comment(self):
        text = "FOO=bar  # trailing comment\n"
        self.assertEqual(bridge.parse_env_text(text), {"FOO": "bar"})

    def test_strips_surrounding_quotes(self):
        text = 'FOO="bar baz"\nQUX=\'single\'\n'
        self.assertEqual(bridge.parse_env_text(text), {"FOO": "bar baz", "QUX": "single"})

    def test_preserves_commas_and_spaces_in_value(self):
        text = "MMM_ALLOWED_USER_IDS=111, 222, 333\n"
        self.assertEqual(
            bridge.parse_env_text(text), {"MMM_ALLOWED_USER_IDS": "111, 222, 333"}
        )


class ValidateCustomAgentTargetTests(unittest.TestCase):
    def test_url_only_ok(self):
        bridge.validate_custom_agent_target("http://x", None)

    def test_cmd_only_ok(self):
        bridge.validate_custom_agent_target(None, "python x.py")

    def test_neither_raises(self):
        with self.assertRaises(ValueError):
            bridge.validate_custom_agent_target("", "")

    def test_both_raises(self):
        with self.assertRaises(ValueError):
            bridge.validate_custom_agent_target("http://x", "python x.py")


if __name__ == "__main__":
    unittest.main()

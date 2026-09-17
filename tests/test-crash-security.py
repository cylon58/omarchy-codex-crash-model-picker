#!/usr/bin/env python3
"""Exercise crash input boundaries without launching agents or notifications."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CrashSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.capture = self.path / "capture"
        self.journal = self.path / "journal"
        self.journal.write_text("")
        (self.path / "config.toml").write_text('model = "gpt-5.6-sol"\n')
        self.env = dict(os.environ, PATH=f"{self.path}:{os.environ['PATH']}",
                        CODEX_HOME=str(self.path), CAPTURE=str(self.capture),
                        JOURNAL=str(self.journal), OMARCHY_CRASH_IGNORE="",
                        OMARCHY_CRASH_DEDUPE_SECONDS="60")
        capture = 'printf "%s\\0" "$@" >> "$CAPTURE"\n'
        commands = {
            "codex": capture,
            "omarchy-agent": capture,
            "omarchy-agent-crash": capture,
            "omarchy-launch-tui": capture,
            "omarchy-notification-send": capture,
            "omarchy-notification-wait": "exit 0\n",
            "omarchy-default-agent": 'echo "${TEST_AGENT:-codex}"\n',
            "journalctl": 'cat "$JOURNAL"\n',
            "coredumpctl": 'echo UNTRUSTED_TIMESTAMP_MARKER\n',
            "gum": 'case "$*" in *"choose a Codex model"*) echo "GPT-5.6 Sol — most capable 5.6";; *) echo medium;; esac\n',
        }
        for name, body in commands.items():
            command = self.path / name
            command.write_text("#!/bin/bash\n" + body)
            command.chmod(0o700)

    def run_command(self, name, *args):
        return subprocess.run([str(ROOT / "bin" / name), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def captured(self):
        return self.capture.read_bytes().decode().split("\0")[:-1] if self.capture.exists() else []

    def event(self, **overrides):
        return dict(COREDUMP_PID="12345", COREDUMP_COMM="chromium",
                    COREDUMP_EXE="/usr/lib/chromium/chromium",
                    COREDUMP_SIGNAL_NAME="SIGILL", **overrides)

    def test_legacy_metadata_never_enters_codex_prompt(self):
        result = self.run_command("codex-crash-diagnose", "--terminal", "12345",
                                  "name\nCOMM_MARKER", "/tmp/EXE_MARKER", "SIGNAL_MARKER")
        self.assertEqual(result.returncode, 0, result.stderr)
        prompt = self.captured()[-1]
        self.assertIn("12345", prompt)
        for marker in ("COMM_MARKER", "EXE_MARKER", "SIGNAL_MARKER", "UNTRUSTED_TIMESTAMP_MARKER"):
            self.assertNotIn(marker, prompt)

    def test_terminal_and_dispatch_forward_only_pid(self):
        for command in ("codex-crash-diagnose", "codex-crash-dispatch"):
            with self.subTest(command=command):
                self.capture.unlink(missing_ok=True)
                result = self.run_command(command, "12345", "ignored\nMARKER", "/tmp/marker", "SIGILL")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.captured()[2:], ["--terminal", "12345"])

    def test_other_agents_receive_pid_only_prompt(self):
        self.env["TEST_AGENT"] = "claude"
        result = self.run_command("codex-crash-dispatch", "12345", "COMM_MARKER", "EXE_MARKER", "SIGNAL_MARKER")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.captured()
        self.assertEqual(args[0], "--prompt")
        self.assertIn("12345", args[1])
        self.assertNotIn("MARKER", args[1])

    def test_invalid_pids_cannot_launch_anything(self):
        for pid in ("", "0", "-1", "01", "1\n2", "123\n", "1;echo bad", "2147483648", "9" * 100):
            for command, prefix in (("codex-crash-diagnose", ["--terminal"]),
                                    ("codex-crash-dispatch", []),
                                    ("omarchy-crash-watch", ["--announce"])):
                with self.subTest(pid=pid, command=command):
                    self.capture.unlink(missing_ok=True)
                    result = self.run_command(command, *prefix, pid)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(self.captured(), [])

    def test_notification_action_contains_only_pid(self):
        result = self.run_command("omarchy-crash-watch", "--announce", "12345", "chromium")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.captured()
        self.assertIn("Process crashed: chromium", args)
        self.assertEqual(args[args.index("--exec") + 2:], ["12345"])

    def test_announce_rejects_display_controls(self):
        for character in ("\n", "\r", "\t", "\x1b", "\x7f", "\x85"):
            with self.subTest(character=repr(character)):
                result = self.run_command("omarchy-crash-watch", "--announce", "12345", "bad" + character, "/tmp/ignored", "SIGILL")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.captured(), [])

    def test_journal_rejects_controls_before_shell_decoding(self):
        events = []
        for code in [*range(32), *range(127, 160)]:
            event = self.event()
            event["COREDUMP_COMM"] = "bad" + chr(code)
            events.append(event)
        for field, value in (("COREDUMP_PID", "12345\n"), ("COREDUMP_PID", [49, 50]),
                             ("COREDUMP_COMM", [65, 0, 66]), ("COREDUMP_COMM", False),
                             ("COREDUMP_COMM", None)):
            event = self.event()
            event[field] = value
            events.append(event)
        self.journal.write_text("\n".join(json.dumps(event) for event in events) + "\n")
        self.run_command("omarchy-crash-watch")
        self.assertEqual(self.captured(), [])

    def test_valid_journal_event_survives_bad_event_and_deduplicates(self):
        event = self.event()
        event["COREDUMP_EXE"] = "/tmp/untrusted\nEXE_MARKER"
        self.journal.write_text("invalid json\n" + (json.dumps(event) + "\n") * 2)
        result = self.run_command("omarchy-crash-watch")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.captured()
        self.assertEqual(args.count("--exec"), 1)
        self.assertEqual(args[args.index("--exec") + 2:], ["12345"])


if __name__ == "__main__":
    unittest.main()

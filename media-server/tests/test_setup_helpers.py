"""Unit tests for install.sh's pure logic (media-server/lib/setup_helpers.py).

Run:  python3 -m unittest discover -s media-server/tests
Also works under pytest.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "..", "lib")
sys.path.insert(0, os.path.abspath(LIB))

import setup_helpers as sh  # noqa: E402


class RenderEnv(unittest.TestCase):
    BASE = "JACKETT_APIKEY=\nSITE_USER=\nSITE_PASS=\nWARP_ADDRESS_V4=172.16.0.2/32\n"

    def test_replaces_existing_key_in_place(self):
        out = sh.render_env(self.BASE, {"SITE_USER": "alice"})
        self.assertIn("SITE_USER=alice\n", out)
        # order preserved: still before SITE_PASS
        self.assertLess(out.index("SITE_USER"), out.index("SITE_PASS"))

    def test_appends_missing_key(self):
        out = sh.render_env("FOO=1\n", {"BAR": "2"})
        self.assertIn("FOO=1\n", out)
        self.assertIn("BAR=2\n", out)

    def test_blank_does_not_wipe_existing_value(self):
        text = "SITE_PASS=keepme\n"
        out = sh.render_env(text, {"SITE_PASS": ""})
        self.assertIn("SITE_PASS=keepme\n", out)

    def test_blank_sets_when_currently_empty(self):
        out = sh.render_env("SITE_PASS=\n", {"SITE_PASS": ""})
        self.assertIn("SITE_PASS=\n", out)

    def test_special_characters_preserved(self):
        secret = "p@ss=w/rd+key=="
        out = sh.render_env(self.BASE, {"SITE_PASS": secret})
        self.assertIn(f"SITE_PASS={secret}\n", out)

    def test_only_targeted_line_changes(self):
        out = sh.render_env(self.BASE, {"SITE_USER": "x"})
        self.assertIn("WARP_ADDRESS_V4=172.16.0.2/32\n", out)

    def test_appends_newline_before_key_when_missing_trailing_nl(self):
        out = sh.render_env("FOO=1", {"BAR": "2"})
        self.assertEqual(out, "FOO=1\nBAR=2\n")


class PatchJackett(unittest.TestCase):
    def test_enables_cors_and_links_flaresolverr(self):
        cfg, changed = sh.patch_jackett_config(
            {"APIKey": "k", "AllowCORS": False,
             "LocalBindAddress": "*", "AllowExternal": True},
            "http://flaresolverr:8191")
        self.assertTrue(changed)
        self.assertTrue(cfg["AllowCORS"])
        self.assertEqual(cfg["FlareSolverrUrl"], "http://flaresolverr:8191")
        self.assertEqual(cfg["APIKey"], "k")  # untouched

    def test_missing_cors_treated_as_off(self):
        cfg, changed = sh.patch_jackett_config({"APIKey": "k"}, "http://fs:8191")
        self.assertTrue(changed)
        self.assertTrue(cfg["AllowCORS"])

    def test_fixes_localhost_bind(self):
        cfg, changed = sh.patch_jackett_config(
            {"APIKey": "k", "AllowCORS": True, "FlareSolverrUrl": "http://fs:8191",
             "LocalBindAddress": "127.0.0.1", "AllowExternal": True},
            "http://fs:8191")
        self.assertTrue(changed)
        self.assertEqual(cfg["LocalBindAddress"], "*")

    def test_enables_allow_external(self):
        cfg, changed = sh.patch_jackett_config(
            {"APIKey": "k", "AllowCORS": True, "FlareSolverrUrl": "http://fs:8191",
             "LocalBindAddress": "*", "AllowExternal": False},
            "http://fs:8191")
        self.assertTrue(changed)
        self.assertTrue(cfg["AllowExternal"])

    def test_no_change_when_already_configured(self):
        cfg = {"APIKey": "k", "AllowCORS": True, "FlareSolverrUrl": "http://fs:8191",
               "LocalBindAddress": "*", "AllowExternal": True}
        _, changed = sh.patch_jackett_config(dict(cfg), "http://fs:8191")
        self.assertFalse(changed)


class MergeTorrServer(unittest.TestCase):
    def test_applies_defaults_and_preserves_other_fields(self):
        current = {"CacheSize": 1, "SomeOtherFlag": True, "ReaderReadAHead": 95}
        merged = sh.merge_torrserver_settings(current)
        self.assertEqual(merged["CacheSize"], 2147483648)
        self.assertEqual(merged["ConnectionsLimit"], 1000)
        self.assertEqual(merged["PeersListenPort"], 42116)
        self.assertTrue(merged["SomeOtherFlag"])        # preserved
        self.assertEqual(merged["ReaderReadAHead"], 95)  # preserved
        self.assertIsNot(merged, current)                # no mutation of input

    def test_explicit_override_wins(self):
        merged = sh.merge_torrserver_settings({}, CacheSize=999)
        self.assertEqual(merged["CacheSize"], 999)


class Cli(unittest.TestCase):
    """Exercise the CLI the way install.sh calls it."""
    def _run(self, *args, **kw):
        return subprocess.run(
            [sys.executable, os.path.join(LIB, "setup_helpers.py"), *args],
            capture_output=True, text=True, **kw)

    def test_render_env_cli_writes_file(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, ".env.example")
            dest = os.path.join(d, ".env")
            with open(src, "w") as f:
                f.write("SITE_USER=\nWARP_ADDRESS_V4=172.16.0.2/32\n")
            r = self._run("render-env", src, dest, "--set", "SITE_USER=bob")
            self.assertEqual(r.returncode, 0, r.stderr)
            with open(dest) as f:
                self.assertIn("SITE_USER=bob", f.read())

    def test_patch_jackett_cli_prints_key(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "ServerConfig.json")
            with open(p, "w") as f:
                json.dump({"APIKey": "abc123", "AllowCORS": False}, f)
            r = self._run("patch-jackett", p, "http://flaresolverr:8191")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "abc123")
            with open(p) as f:
                self.assertTrue(json.load(f)["AllowCORS"])

    def test_patch_jackett_cli_missing_file_is_soft(self):
        r = self._run("patch-jackett", "/nonexistent/ServerConfig.json", "http://x")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()

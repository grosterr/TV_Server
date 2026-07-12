#!/usr/bin/env python3
"""Pure, unit-testable helpers used by install.sh.

Keeping this logic out of shell heredocs makes it importable and testable.
Every function that only transforms data is side-effect free; the thin CLI at
the bottom wires them to files / HTTP for install.sh to call.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from typing import Dict, Tuple

# Keys the installer may write into .env (order preserved for stable output).
ENV_KEYS = ("JACKETT_APIKEY", "WARP_PRIVATE_KEY", "WARP_ADDRESS_V4")

TORRSERVER_DEFAULTS = dict(
    CacheSize=2147483648, ConnectionsLimit=1000,
    PeersListenPort=42116, TorrentDisconnectTimeout=3600,
)


def render_env(text: str, overrides: Dict[str, str]) -> str:
    """Return .env `text` with `overrides` applied.

    Rules that matter for idempotent re-runs:
      * an existing line `KEY=...` is replaced in place (order kept);
      * a missing key is appended;
      * a BLANK override never wipes an existing non-empty value (so re-running
        without re-entering a password keeps the old one).
    """
    for key, value in overrides.items():
        k = re.escape(key)
        has_value = re.search(rf"(?m)^{k}=.+$", text) is not None
        if value == "" and has_value:
            continue
        if re.search(rf"(?m)^{k}=", text):
            text = re.sub(rf"(?m)^{k}=.*$", f"{key}={value}", text)
        else:
            if text and not text.endswith("\n"):
                text += "\n"
            text += f"{key}={value}\n"
    return text


def patch_jackett_config(cfg: Dict, flaresolverr_url: str) -> Tuple[Dict, bool]:
    """Enable CORS and link FlareSolverr in a parsed ServerConfig.json dict.

    AllowCORS lets the Lampa web UI (a different origin) read Jackett's
    responses -- without it the TV shows "parser not responding".
    LocalBindAddress must be '*' inside Docker so port-mapped traffic
    (which arrives on the container's external NIC, not loopback) is accepted.
    Returns (cfg, changed).
    """
    changed = False
    if not cfg.get("AllowCORS"):
        cfg["AllowCORS"] = True
        changed = True
    if cfg.get("FlareSolverrUrl") != flaresolverr_url:
        cfg["FlareSolverrUrl"] = flaresolverr_url
        changed = True
    if cfg.get("LocalBindAddress") == "127.0.0.1":
        cfg["LocalBindAddress"] = "*"
        changed = True
    if not cfg.get("AllowExternal"):
        cfg["AllowExternal"] = True
        changed = True
    return cfg, changed


def merge_torrserver_settings(current: Dict, **overrides) -> Dict:
    """Merge tuning values onto TorrServer's current settings, preserving the
    rest (TorrServer's /settings set replaces the whole object)."""
    merged = dict(current)
    merged.update({**TORRSERVER_DEFAULTS, **overrides})
    return merged


# --------------------------------------------------------------------------- #
# --------------------------------------------------------------------------- #
#  Thin I/O wrappers + CLI (used by install.sh; not covered by unit tests).
# --------------------------------------------------------------------------- #
def _cmd_render_env(args) -> int:
    overrides = {}
    for pair in args.set or []:
        if "=" not in pair:
            print(f"--set expects KEY=VALUE, got {pair!r}", file=sys.stderr)
            return 2
        k, v = pair.split("=", 1)
        overrides[k] = v
    with open(args.src, encoding="utf-8") as f:
        text = f.read()
    with open(args.dest, "w", encoding="utf-8") as f:
        f.write(render_env(text, overrides))
    return 0


def _cmd_patch_jackett(args) -> int:
    try:
        with open(args.path, encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        print("")  # no key available yet
        return 0
    cfg, changed = patch_jackett_config(cfg, args.flaresolverr_url)
    if changed:
        try:
            with open(args.path, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=2)
        except OSError as exc:
            # Still surface the key we read; the caller warns about the rest.
            print(f"warning: could not write {args.path}: {exc}", file=sys.stderr)
    print(cfg.get("APIKey", ""))
    return 0


def _cmd_tune_torrserver(args) -> int:
    def call(path, payload):
        req = urllib.request.Request(
            args.base + path, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
        return urllib.request.urlopen(req, timeout=8)
    try:
        current = json.load(call("/settings", {"action": "get"}))
        merged = merge_torrserver_settings(current)
        call("/settings", {"action": "set", "sets": merged}).read()
    except Exception as exc:  # noqa: BLE001 — installer prints a soft warning
        print(f"unreachable: {exc}", file=sys.stderr)
        return 1
    print("  + cache 2 GiB, 1000 connections, peer port 42116")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("render-env")
    p.add_argument("src"); p.add_argument("dest")
    p.add_argument("--set", action="append", metavar="KEY=VALUE")
    p.set_defaults(func=_cmd_render_env)

    p = sub.add_parser("patch-jackett")
    p.add_argument("path"); p.add_argument("flaresolverr_url")
    p.set_defaults(func=_cmd_patch_jackett)

    p = sub.add_parser("tune-torrserver")
    p.add_argument("base")
    p.set_defaults(func=_cmd_tune_torrserver)


    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

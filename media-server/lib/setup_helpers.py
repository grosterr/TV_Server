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
ENV_KEYS = ("JACKETT_APIKEY", "WARP_PRIVATE_KEY", "WARP_ADDRESS_V4",
            "ENABLE_FLARESOLVERR")

TORRSERVER_DEFAULTS = dict(
    # 2**31-1 (int32 max): a full 2 GiB is 2**31, which overflows TorrServer's
    # signed-int32 cache field on 32-bit (armv7) builds and wraps negative.
    CacheSize=2147483647, ConnectionsLimit=1000,
    PeersListenPort=42116, TorrentDisconnectTimeout=3600,
    PreloadCache=10,  # % of cache preloaded before playback (quick start)
)

# GitHub repo the update checker queries for the latest release.
GITHUB_REPO = "grosterr/torlamp"


def parse_version(tag: str) -> Tuple[int, int, int]:
    """Normalize a version tag to a comparable (major, minor, patch) tuple.

    Tolerant of real-world tags: 'v1' -> (1,0,0), '1.1' -> (1,1,0),
    'v1.2.3-beta4' -> (1,2,3). Unparsable/empty -> (0,0,0), which makes any
    real release "newer" — exactly right for old installs without a VERSION
    file.
    """
    nums = [int(n) for n in re.findall(r"\d+", tag or "")[:3]]
    while len(nums) < 3:
        nums.append(0)
    return tuple(nums)  # type: ignore[return-value]


def is_newer(remote_tag: str, local_version: str) -> bool:
    """True if the release tag is strictly newer than the installed version."""
    return parse_version(remote_tag) > parse_version(local_version)


# RAM-cache bounds for pick_cache_size (bytes).
CACHE_MIN = 256 * 1024 * 1024   # even a 1 GB Raspberry Pi can spare this
# A full 2 GiB (2**31) overflows TorrServer's signed-int32 cache field on
# 32-bit (armv7) builds and wraps negative, so cap one byte below at int32 max.
# More than ~2 GiB gives no benefit for streaming anyway.
CACHE_MAX = 2 ** 31 - 1         # 2147483647 — largest int32-safe cache


def pick_cache_size(total_ram_bytes: int | None) -> int:
    """Pick a TorrServer RAM-cache size for a host with `total_ram_bytes`.

    A quarter of total RAM, clamped to [256 MiB, 2 GiB] — so a 2 GB
    Raspberry Pi gets 512 MiB instead of the old fixed 2 GiB (which OOMed
    the host). Unknown RAM (None/0) falls back to the 2 GiB maximum.
    """
    if not total_ram_bytes or total_ram_bytes <= 0:
        return CACHE_MAX
    return max(CACHE_MIN, min(CACHE_MAX, total_ram_bytes // 4))


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
            # lambda replacement: keeps backslashes in `value` literal
            # (re.sub would otherwise expand them as escape sequences).
            text = re.sub(rf"(?m)^{k}=.*$", lambda _: f"{key}={value}", text)
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
    # Explicit --cache-size (from .env) wins; otherwise size from host RAM.
    cache = args.cache_size or pick_cache_size(args.total_ram)
    try:
        current = json.load(call("/settings", {"action": "get"}))
        merged = merge_torrserver_settings(current, CacheSize=cache)
        call("/settings", {"action": "set", "sets": merged}).read()
    except Exception as exc:  # noqa: BLE001 — installer prints a soft warning
        print(f"unreachable: {exc}", file=sys.stderr)
        return 1
    gib = cache / 2 ** 30
    print(f"  + cache {gib:.2g} GiB, 1000 connections, "
          "peer port 42116, preload 10%")
    return 0


def _cmd_check_update(args) -> int:
    """Print the latest release tag if it's newer than --current; print
    nothing when up-to-date. Network problems exit 1 quietly — the installer
    treats the check as best-effort."""
    url = f"https://api.github.com/repos/{args.repo}/releases/latest"
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "torlamp-installer"})
    try:
        tag = json.load(urllib.request.urlopen(req, timeout=6)).get("tag_name", "")
    except Exception:  # noqa: BLE001 — offline / rate-limited: stay quiet
        return 1
    if tag and is_newer(tag, args.current):
        print(tag)
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
    p.add_argument("--cache-size", type=int, default=0,
                   help="explicit RAM cache in bytes (overrides --total-ram)")
    p.add_argument("--total-ram", type=int, default=0,
                   help="host RAM in bytes; cache is picked from it")
    p.set_defaults(func=_cmd_tune_torrserver)

    p = sub.add_parser("check-update")
    p.add_argument("--repo", default=GITHUB_REPO)
    p.add_argument("--current", required=True,
                   help="installed version (contents of the VERSION file)")
    p.set_defaults(func=_cmd_check_update)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

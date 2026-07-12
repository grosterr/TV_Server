#!/usr/bin/env python3
"""Pure, unit-testable helpers used by install.sh.

Keeping this logic out of shell heredocs makes it importable and testable.
Every function that only transforms data is side-effect free; the thin CLI at
the bottom wires them to files / HTTP for install.sh to call.
"""
from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Dict, List, Tuple

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
    responses — without it the TV shows "parser not responding".
    Returns (cfg, changed).
    """
    changed = False
    if not cfg.get("AllowCORS"):
        cfg["AllowCORS"] = True
        changed = True
    if cfg.get("FlareSolverrUrl") != flaresolverr_url:
        cfg["FlareSolverrUrl"] = flaresolverr_url
        changed = True
    return cfg, changed


def merge_torrserver_settings(current: Dict, **overrides) -> Dict:
    """Merge tuning values onto TorrServer's current settings, preserving the
    rest (TorrServer's /settings set replaces the whole object)."""
    merged = dict(current)
    merged.update({**TORRSERVER_DEFAULTS, **overrides})
    return merged


# --------------------------------------------------------------------------- #
#  Jackett indexer management — parse the running Jackett and add indexers on
#  demand, driven purely by each indexer's own config form (no hardcoded list).
# --------------------------------------------------------------------------- #
def classify_indexer(type_str: str) -> str:
    """Normalize Jackett's indexer type to public / semi-private / private."""
    t = (type_str or "").lower()
    if t == "public":
        return "public"
    if "semi" in t:
        return "semi-private"
    return "private"


def field_kind(item: Dict) -> str:
    """Classify one Jackett config item into how the installer should treat it:
    text | password | bool | captcha | recaptcha | skip."""
    t = (item.get("type") or "").lower()
    iid = (item.get("id") or "").lower()
    if t in ("displayinfo", "info", "inputinfo"):
        return "skip"
    if "recaptcha" in t:
        return "recaptcha"          # Google reCAPTCHA — not solvable in a CLI
    if "captcha" in t or "captcha" in iid:
        return "captcha"
    if t in ("inputbool", "inputcheckbox"):
        return "bool"
    if t == "password" or "pass" in iid:
        return "password"
    if iid == "sitelink":
        return "skip"               # keep the indexer's default site link
    if t in ("inputstring", "inputtags", "inputselect"):
        return "text"
    return "skip"


def fillable_fields(items: List[Dict]) -> List[Dict]:
    """Config items that need a value from the user (public indexers have none)."""
    return [it for it in items if field_kind(it) in ("text", "password", "bool", "captcha")]


def build_config_body(items: List[Dict], answers: Dict[str, object]) -> List[Dict]:
    """Return a copy of the config items with `answers[id]` applied to values."""
    out = []
    for it in items:
        it = dict(it)
        if it.get("id") in answers:
            it["value"] = answers[it["id"]]
        out.append(it)
    return out


def parse_selection(raw: str, count: int) -> List[int]:
    """Parse '1,3,5-7' into sorted 0-based indices within [0, count)."""
    picks = set()
    for part in raw.replace(";", ",").split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            if a.strip().isdigit() and b.strip().isdigit():
                for i in range(int(a), int(b) + 1):
                    if 1 <= i <= count:
                        picks.add(i - 1)
        elif part.isdigit():
            i = int(part)
            if 1 <= i <= count:
                picks.add(i - 1)
    return sorted(picks)


def _api(base: str, path: str, apikey: str) -> str:
    sep = "&" if "?" in path else "?"
    return f"{base.rstrip('/')}{path}{sep}apikey={urllib.parse.quote(apikey)}"


def jk_list_indexers(base: str, apikey: str) -> List[Dict]:
    with urllib.request.urlopen(_api(base, "/api/v2.0/indexers", apikey), timeout=20) as r:
        return json.load(r)


def jk_get_config(base: str, indexer_id: str, apikey: str) -> List[Dict]:
    with urllib.request.urlopen(_api(base, f"/api/v2.0/indexers/{indexer_id}/config", apikey), timeout=20) as r:
        return json.load(r)


def jk_set_config(base: str, indexer_id: str, apikey: str, items: List[Dict]) -> str:
    req = urllib.request.Request(
        _api(base, f"/api/v2.0/indexers/{indexer_id}/config", apikey),
        data=json.dumps(items).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.read().decode(errors="replace")


def _save_captcha(item: Dict, indexer_id: str) -> str:
    """Best-effort: pull a captcha image out of a config item and save it to a
    file the user can open. Returns the path, or '' if no image was found."""
    candidates = []
    val = item.get("value")
    if isinstance(val, str):
        candidates.append(val)
    elif isinstance(val, dict):
        candidates += [v for v in val.values() if isinstance(v, str)]
    for c in candidates:
        data, ext = None, "png"
        if c.startswith("data:image"):
            head, b64 = c.split(",", 1)
            data = base64.b64decode(b64)
            if "jpeg" in head or "jpg" in head:
                ext = "jpg"
        elif c.startswith("http"):
            try:
                with urllib.request.urlopen(c, timeout=15) as r:
                    data = r.read()
            except OSError:
                data = None
        if data:
            path = os.path.abspath(f"captcha_{indexer_id}.{ext}")
            with open(path, "wb") as f:
                f.write(data)
            return path
    return ""


# --- Localized strings for the interactive add-indexers flow ----------------
_I18N = {
    "en": {
        "list_fail": "  Could not read indexers from Jackett: {e}",
        "none": "  No new indexers available to add.",
        "header": "Available search indexers (Jackett):",
        "select": "Numbers to add (e.g. 1,3,5-7), or Enter to finish: ",
        "recaptcha": "  {name}: needs Google reCAPTCHA — add it in the Jackett web UI ({base}).",
        "captcha_saved": "  Captcha image saved to: {path} — open it to read the code.",
        "captcha_prompt": "  Captcha text: ",
        "added_ok": "  + {name} added.",
        "added_fail": "  ! {name} failed: {e}",
        "use_web": "    You can finish this one in the Jackett web UI: {base}",
        "cfg_fail": "  ! {name}: could not read its config: {e}",
        "more": "Add more? [y/N]: ",
        "done": "  Done adding indexers.",
    },
    "uk": {
        "list_fail": "  Не вдалося прочитати індексатори з Jackett: {e}",
        "none": "  Немає нових індексаторів для додавання.",
        "header": "Доступні пошукові індексатори (Jackett):",
        "select": "Номери для додавання (напр. 1,3,5-7) або Enter, щоб завершити: ",
        "recaptcha": "  {name}: потребує Google reCAPTCHA — додайте у веб-інтерфейсі Jackett ({base}).",
        "captcha_saved": "  Зображення капчі збережено: {path} — відкрийте, щоб прочитати код.",
        "captcha_prompt": "  Текст капчі: ",
        "added_ok": "  + {name} додано.",
        "added_fail": "  ! {name} не вдалося: {e}",
        "use_web": "    Можна завершити у веб-інтерфейсі Jackett: {base}",
        "cfg_fail": "  ! {name}: не вдалося прочитати конфіг: {e}",
        "more": "Додати ще? [y/N]: ",
        "done": "  Додавання індексаторів завершено.",
    },
    "ru": {
        "list_fail": "  Не удалось прочитать индексаторы из Jackett: {e}",
        "none": "  Нет новых индексаторов для добавления.",
        "header": "Доступные поисковые индексаторы (Jackett):",
        "select": "Номера для добавления (напр. 1,3,5-7) или Enter, чтобы завершить: ",
        "recaptcha": "  {name}: нужна Google reCAPTCHA — добавьте в веб-интерфейсе Jackett ({base}).",
        "captcha_saved": "  Изображение капчи сохранено: {path} — откройте, чтобы прочитать код.",
        "captcha_prompt": "  Текст капчи: ",
        "added_ok": "  + {name} добавлен.",
        "added_fail": "  ! {name} не удалось: {e}",
        "use_web": "    Можно завершить в веб-интерфейсе Jackett: {base}",
        "cfg_fail": "  ! {name}: не удалось прочитать конфиг: {e}",
        "more": "Добавить ещё? [y/N]: ",
        "done": "  Добавление индексаторов завершено.",
    },
}
_YES = ("y", "yes", "т", "так", "д", "да")


def _add_one(base: str, apikey: str, ix: Dict, T: Dict) -> None:
    iid = ix["id"]
    name = ix.get("name") or iid
    try:
        items = jk_get_config(base, iid, apikey)
    except (OSError, ValueError) as exc:
        print(T["cfg_fail"].format(name=name, e=exc))
        return
    answers: Dict[str, object] = {}
    for it in items:
        kind = field_kind(it)
        label = it.get("name") or it.get("id")
        if kind == "skip":
            continue
        if kind == "recaptcha":
            print(T["recaptcha"].format(name=name, base=base))
            return
        if kind == "captcha":
            path = _save_captcha(it, iid)
            if path:
                print(T["captcha_saved"].format(path=path))
            answers[it["id"]] = input(T["captcha_prompt"]).strip()
        elif kind == "password":
            answers[it["id"]] = getpass.getpass(f"  {label}: ")
        elif kind == "bool":
            answers[it["id"]] = input(f"  {label} [y/N]: ").strip().lower() in _YES
        else:  # text
            answers[it["id"]] = input(f"  {label}: ").strip()
    try:
        jk_set_config(base, iid, apikey, build_config_body(items, answers))
        print(T["added_ok"].format(name=name))
    except urllib.error.HTTPError as exc:
        print(T["added_fail"].format(name=name, e=exc.read().decode(errors="replace")[:200]))
        print(T["use_web"].format(base=base))
    except (OSError, ValueError) as exc:
        print(T["added_fail"].format(name=name, e=exc))
        print(T["use_web"].format(base=base))


def add_indexers_interactive(base: str, apikey: str, lang: str = "en") -> int:
    """List Jackett's unconfigured indexers and let the user add any of them.
    Public ones add with no input; semi-private/private prompt for whatever
    their config form asks (login, password, image captcha)."""
    T = _I18N.get(lang, _I18N["en"])
    try:
        indexers = jk_list_indexers(base, apikey)
    except (OSError, ValueError) as exc:
        print(T["list_fail"].format(e=exc))
        return 1
    avail = sorted((i for i in indexers if not i.get("configured")),
                   key=lambda x: (x.get("name") or "").lower())
    while avail:
        print("\n" + T["header"])
        for n, ix in enumerate(avail, 1):
            print(f"  {n:>3}. {(ix.get('name') or ix['id']):32} [{classify_indexer(ix.get('type'))}]")
        raw = input("\n" + T["select"]).strip()
        if not raw:
            break
        for idx in parse_selection(raw, len(avail)):
            _add_one(base, apikey, avail[idx], T)
        try:
            done = {i["id"] for i in jk_list_indexers(base, apikey) if i.get("configured")}
            avail = [i for i in avail if i["id"] not in done]
        except (OSError, ValueError):
            pass
        if not avail or input("\n" + T["more"]).strip().lower() not in _YES:
            break
    print(T["done"])
    return 0


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

    p = sub.add_parser("add-indexers")
    p.add_argument("base"); p.add_argument("apikey")
    p.add_argument("--lang", default="en", choices=("en", "uk", "ru"))
    p.set_defaults(func=lambda a: add_indexers_interactive(a.base, a.apikey, a.lang))

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())

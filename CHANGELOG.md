# Changelog

## Unreleased

Security & resource hardening plus a built-in update system — same stack,
safer defaults.

### Changes
- **Update system** — the installer now knows its version (the `VERSION` file
  at the bundle root) and checks GitHub for a newer release when a server is
  already installed. If one exists, an **UPDATE** menu entry downloads it,
  replaces the stack files (data — `.env`, `jackett_config/`,
  `torrserver_data/`, `warp/` — is untouched), syncs the TorrServer image pin
  in `.env` with the shipped default, and relaunches the fresh installer as
  repair with a `docker compose pull`. Old installs without a `VERSION` file
  are treated as version 0, so they're offered the update too.
  Non-interactive: `ACTION=update`; opt out of the check with
  `TORLAMP_SKIP_UPDATE_CHECK=1`. Git checkouts are never overwritten (use
  `git pull`).
- **WARP profile generation fixed on ARM** — the installer now picks the right
  `wgcf` binary for the host architecture (amd64 / arm64 / armv7), so IP hiding
  works on Raspberry Pi and ARM NAS boxes instead of silently failing.
- **SHA256-verified downloads** — the pinned `wgcf` binary is checked against a
  known checksum before it runs.
- **FlareSolverr is now optional** (default: on) — it's the heaviest component
  (headless browser, ~0.5 GB RAM). The installer asks and records the choice as
  `ENABLE_FLARESOLVERR` in `.env`; disable it on low-RAM boxes and you only lose
  Cloudflare-protected trackers. Its container is also capped at 1 GB RAM.
- **Adaptive TorrServer cache** — with `TORRSERVER_CACHE_SIZE` left empty the
  cache is now a quarter of host RAM, clamped to 256 MiB – 2 GiB, so a
  Raspberry Pi no longer gets a fixed 2 GiB cache that OOMed the host. Set an
  explicit value in `.env` to override.
- **gluetun pinned to `v3`** — the WARP tunnel image no longer floats on
  `:latest`; all torrent traffic rides it, so no surprise breaking upgrades.
- **WARP works on 10.x / 172.16.x LANs** — the tunnel firewall now allows all
  three RFC1918 ranges, not just `192.168.0.0/16`.
- **TorrServer waits for the tunnel** — in the WARP variant it starts only after
  gluetun reports healthy (no more first seconds without network).
- **Secrets file permissions** — `install.sh` now chmods `.env` and
  `lampa_settings.txt` to owner-only (0600).
- **WARP IPv4 address parsing** — only the IPv4 part of the wgcf `Address` line
  is written to `WARP_ADDRESS_V4` (the IPv6 tail is dropped).

## v1.0

First stable **Torlamp** release. Everything from the v0.5.x betas — the Torlamp
rebrand, root-level installers, and the switch to Jackett's web UI for indexers —
consolidated and hardened. Same three-service stack and ports; still no backend.

### Changes
- **Rebranded to Torlamp** (Torrent + Lampa) across all docs and installers,
  with a localized tagline and a start-up banner. Service/container names and the
  `media-server/` folder are unchanged.
- **Root-level installer launchers** — `install.bat` / `install.sh` now sit at the
  top of the project (and this ZIP) and delegate to the real installer in
  `media-server/`. No more digging through folders.
- **Indexers via the Jackett web UI** — the installer now opens Jackett in your
  browser to add trackers there (100% captcha/login compatibility), instead of a
  CLI prompt that broke on changing tracker auth. The CLI add-indexer flow was removed.
- **`lampa_settings.txt`** — the installer saves the ready TorrServer/Jackett URLs
  and API key (plus Lampa setup steps) to this file so you always have them handy.
- **Network-adapter picker** — on a multi-IP machine the installer asks which
  LAN IP to advertise to Lampa.
- **Jackett reachability fix** — bind Jackett to all interfaces
  (`LocalBindAddress=*`, `AllowExternal`) so Docker port-mapping works from the host/TV.
- **WARP REPAIR fix** — regenerate the WARP key on REPAIR if it's missing, so the
  `warp` container (and TorrServer behind it) no longer crash-loops.
- **TorrServer preload default** — the installer now sets a **10%** preload buffer
  (fast playback start; buffer fills while watching). Tune via `TORRSERVER_PRELOAD`
  or the TorrServer panel at `:8090`.
- **Doc accuracy fixes** — `configure.ps1` / API-key note, firewall port `42116`,
  `JACKETT_APIKEY` clarified.
- **Installer robustness** — wait for Jackett to be ready again after its
  post-config restart; enforce LF line endings for shell scripts via `.gitattributes`.

### Install
- **Windows:** download this release, unzip, double-click `install.bat`.
- **Linux / macOS / NAS / Raspberry Pi:** `bash install.sh` from the unzipped folder.

## v0.5.0-beta

First public beta of **Torlamp** — a local media server for the **Lampa** app
(Smart TV / Android TV / PC). It is a Docker Compose stack, so the *same* files
run on Windows, Linux, macOS, NAS and Raspberry Pi (amd64 / arm64) — there are
no per-OS builds. Windows users double-click `install.bat` in the project root;
every other platform runs `bash install.sh` from the root.

### Highlights
- **Guided installer** — one step brings up the stack, generates `.env`,
  auto-reads the Jackett API key (no copy-paste), enables CORS + links
  FlareSolverr (fixes "parser not responding"), tunes TorrServer, and prints
  ready-to-paste Lampa URLs with your LAN IP.
- **Add search indexers on demand from the live Jackett** — no hardcoded
  tracker list. Public indexers add instantly; semi-private / private ones
  prompt for login/password and download any image captcha for you to solve;
  Google reCAPTCHA is deferred to the Jackett web UI.
- **REPAIR / DELETE / QUIT** when a server is already installed.
- **Localized installer & docs** — English / Українська / Русский.
- **Optional Cloudflare WARP** (opt-in) to hide your P2P IP, split into its own
  `docker-compose.warp.yml`; the WARP-free `docker-compose.yml` is the default.
- **Quality**: GitHub Actions CI runs shellcheck, PSScriptAnalyzer, Python unit
  tests, `docker compose config` validation, and a real end-to-end install test.

### Install
- **Windows:** download the release, unzip, double-click `install.bat` in the project root.
- **Linux / macOS / NAS / Raspberry Pi:** `bash install.sh` from the project root.
- New to Docker? See **GETTING-STARTED** ([UA](GETTING-STARTED.md) ·
  [RU](GETTING-STARTED.ru.md) · [EN](GETTING-STARTED.en.md)).

### Beta notes
- TorrServer is pinned to the stable `MatriX.141.10` (upstream crash bug
  YouROK/TorrServer#766); bump `TORRSERVER_VERSION` in `.env` once it's fixed.
- On Windows the indexer auto-add step uses Python if present; otherwise it
  points you to the Jackett web UI at `http://localhost:9117`.

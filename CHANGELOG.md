# Changelog

## v0.5.0-beta

First public beta of **TV_Server** — a local media server for the **Lampa** app
(Smart TV / Android TV / PC). It is a Docker Compose stack, so the *same* files
run on Windows, Linux, macOS, NAS and Raspberry Pi (amd64 / arm64) — there are
no per-OS builds. Windows users double-click `media-server/install.bat`; every
other platform runs `bash media-server/install.sh`.

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
- **Windows:** download the release, unzip, double-click `media-server/install.bat`.
- **Linux / macOS / NAS / Raspberry Pi:** `cd media-server && bash install.sh`.
- New to Docker? See **GETTING-STARTED** ([UA](GETTING-STARTED.md) ·
  [RU](GETTING-STARTED.ru.md) · [EN](GETTING-STARTED.en.md)).

### Beta notes
- TorrServer is pinned to the stable `MatriX.141.10` (upstream crash bug
  YouROK/TorrServer#766); bump `TORRSERVER_VERSION` in `.env` once it's fixed.
- On Windows the indexer auto-add step uses Python if present; otherwise it
  points you to the Jackett web UI at `http://localhost:9117`.

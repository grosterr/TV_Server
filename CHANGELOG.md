# Changelog

## v0.5.1-beta

Rebrand and packaging polish over v0.5.0-beta — same stack and ports; indexer
setup now happens in the Jackett web UI instead of a CLI prompt.

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

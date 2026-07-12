# TV_Server

<p align="center">
  <a href="README.md"><img src="assets/lang-ua.svg" alt="Українська" height="28"></a>
  <a href="README.ru.md"><img src="assets/lang-ru.svg" alt="Русский (СНД)" height="28"></a>
  <a href="README.en.md"><img src="assets/lang-en.svg" alt="English" height="28"></a>
</p>

A local media server built for streaming torrents and aggregated search. Perfectly suited for use with the **Lampa** app on Smart TV, Android TV, or PC.

> 🆕 **New here? Don't know anything about Docker?**
> 👉 Start with the **[step-by-step "from scratch" guide (GETTING-STARTED)](GETTING-STARTED.md)** — it walks you from installing programs to a movie on your TV in plain language.
>
> This README is a technical reference: architecture, optimization, hiding your IP, troubleshooting.

## 🚀 Architecture and components

This stack is deployed in an isolated environment using **Docker Compose** and consists of the following components:

1. **TorrServer** (port `8090`)
   - **Purpose:** Streaming torrents without needing to download the entire file to your hard drive first.
   - **Optimization:** The `configure.ps1` script enables an extended in-RAM cache (2 GB) and raises the P2P connection limit (up to 1000) for maximum bandwidth utilization (up to 300+ Mbit/s). Values are configurable in the `.env` file.
   - Data is cached exclusively in RAM and deleted after viewing.

2. **Jackett** (port `9117`)
   - **Purpose:** A unified proxy server for searching across torrent trackers. It translates search queries from Lampa into requests to specific sites.
   - **Trackers:** Supports adding any public or private trackers (e.g.: Toloka.to, ThePirateBay, 1337x).

3. **FlareSolverr** (port `8191`)
   - **Purpose:** Bypasses Cloudflare protection ("I'm not a robot", JS challenges) on trackers. Without it, Jackett cannot index protected sites (e.g. 1337x) — this capability is exactly what makes aggregators like JacRed/Lampac "richer in sources".
   - Jackett contacts it automatically for problematic trackers; the address is set in `configure.ps1` / `.env` (`JACKETT_FLARESOLVERR_URL`).

---

## 🛠 How to run (Installation)

1. **Preparation:**
   Make sure you have [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed (if you're on Windows) or Docker + Docker Compose (if on Linux).
   **Important for autostart:** In Docker Desktop settings (Settings -> General) enable the **"Start Docker Desktop when you log in"** checkbox. Thanks to the `restart: unless-stopped` parameter, the server will automatically start together with your PC as a background service.

2. **Starting the containers:**
   Open a terminal, navigate to the `media-server` folder and run the command:
   ```bash
   docker compose up -d
   ```

3. **Basic Jackett setup:**
   - Open a browser and go to: `http://localhost:9117`
   - In the top-right corner, copy your **API Key**. You'll need it to connect to Lampa.

4. **Automatic setup (recommended):**
   Instead of adding each tracker manually, use the script. It will configure TorrServer optimization and add all private trackers in one step.
   - Copy the template and fill in your data:
     ```powershell
     Copy-Item .env.example .env   # then edit .env
     ```
   - In `.env` specify `JACKETT_APIKEY` (from the Jackett web interface) and tracker logins/passwords.
   - Run:
     ```powershell
     ./configure.ps1
     ```
   The script is **idempotent** — it can be safely run repeatedly. To add a new private tracker, just add one line to the `$Trackers` array inside `configure.ps1` and the corresponding variables in `.env`.

> 🔒 **Security:** the `.env` file contains passwords and the API key and **does not go into git** (added to `.gitignore`). Never commit it. Public trackers (ThePirateBay, 1337x) don't require a login — they can be added with the **"+ Add indexer"** button in the Jackett web interface.

---

## 📺 Connecting to Lampa

> ℹ️ **About Lampa (official developer FAQ):** Lampa is not a finished product but a **"construction kit"** that you must configure yourself (specify your TorrServer and parser). Official apps: [Lampa Desktop](https://github.com/Kolovatoff/lampa-desktop/releases) (PC), [lampa-app/LAMPA](https://github.com/lampa-app/LAMPA/releases) (Android/TV), [lampa.mx](https://lampa.mx) (web), [yumata/lampa](https://github.com/yumata/lampa) (self-hosting). Community: [t.me/lampa_group](https://t.me/lampa_group).

For Lampa to see your new server and start searching for and playing movies, follow these steps:

### Option A: Android TV / set-top box — via Downloader
The most convenient way for Android TV: the **Downloader** app installs Lampa and the Vimu player from a single code.
1. Install **Downloader by AFTVnews** from Google Play (orange icon with an arrow).
2. Launch it → enter the code **`4384169`** → **Go**. The "APK download" page will open.
3. Select and install **Lampa** (required) and **Vimu Media Player** (external player for DTS/4K). You **don't need** to install Torrserve MatriX — the server is already on your PC.
4. If needed, allow installation from unknown sources for Downloader (the TV will prompt you).

### Option B: Samsung Tizen — via Media Station X
Downloader doesn't work on Samsung (Tizen isn't Android), so:
1. Download **Media Station X** from the official Samsung Apps store.
2. Launch it ➔ **Settings** ➔ **Start Parameter** ➔ **Setup**.
3. Enter `lampa.mx` and confirm. The app will restart and open Lampa.

### Option C: Configuring Lampa itself (all devices)
1. **TorrServer:** Go to **Settings** -> **Torrents**.
   - Enable the use of TorrServer.
   - Specify the **Main link**: `http://[YOUR-PC-IP-ADDRESS]:8090` (for example, `http://192.168.1.165:8090`).
2. **Jackett:** Go to **Settings** -> **Plugins**.
   - Go to the Jackett plugin settings and specify:
   - **Link:** `http://[YOUR-PC-IP-ADDRESS]:9117`
   - **API key:** Paste the key copied from the Jackett web interface.

---

## 🔗 Official Lampa resources (from the developers)

> Source: the pinned [Lampa community FAQ](https://t.me/lampa_group/195951). Lampa is a **"skeleton"** that requires manual configuration; these links lead to the official guides.

**Setting up from scratch:**
- [Instructions (Telegraph)](https://telegra.ph/Nastraivaem-Lampu-s-nulya-06-18) · [GitHub wiki](https://github.com/yumata/lampa/wiki)
- [What to do if the home page is empty / there are no posters](https://t.me/lampa_group/220151)

**Installation by platform:**
- 📱 Android / Android TV: [official APK releases](https://github.com/lampa-app/LAMPA/releases) · [via Downloader (code 4384169)](https://telegra.ph/Ustanovka-prilozhenij-Lampa-Torrserve-Matrix-Vimu-na-Android-TV-s-pomoshchyu-Downloader-11-18)
- 📺 LG / Samsung / Hisense (Vidaa): [guide](https://telegra.ph/USTANOVKA-i-zapusk-na-Lg-Samsung-Hisense-Vidaa-MCX-01-02)
- 💻 PC Windows / Mac / Linux: [Lampa Desktop](https://github.com/Kolovatoff/lampa-desktop/releases) · [Electron for Linux](https://github.com/Boria138/Lampa)
- 🍏 iPhone / iPad / AppleTV: [via the community](https://t.me/lampa_group)

**TorrServer and parser:**
- 🗄 [Official TorrServer installation guide](https://telegra.ph/Ustanovka-Servera-na-vneshnee-ustrojstvo-01-24) · [TorrServer group](https://t.me/TorrServe)
- 🔈 [List of public parsers](https://t.me/lampa_group/247800) · the custom **JacRed** parser ([jacred-fdb](https://github.com/jacred-fdb/jacred)) — an alternative to Jackett used by Lampac
- 🧩 [Lampa plugins](https://t.me/lampa_plugin)

**Other:**
- 🕺 [Cub.red](https://t.me/lampa_group/220151) — a server for syncing bookmarks between devices
- ✈️ [Candle](https://t.me/lampa_group/323324) — sending third-party video links to Lampa from a phone/PC
- 📝 [Report a bug / suggestion](https://github.com/yumata/lampa/issues)

> 💡 **About JacRed vs Jackett:** this project uses **Jackett + FlareSolverr** (tested, works with Cloudflare trackers). JacRed is a lighter "parser" alternative with a ready-made set of trackers; if you ever want to try it — you can run it as a separate container and specify it in Lampa instead of Jackett.

---

## ⚡ Speed optimization at the P2P level

If the speed is low even on torrents with many seeders — the most common cause is that your TorrServer is **unreachable for incoming connections** (behind NAT). Then you can only connect to open peers yourself, but no one can connect to you. This cuts speed dramatically.

**Solution — a fixed port for peers + port forwarding on the router:**

1. **The port is already configured** in this repository: `42116` (TCP+UDP) is opened in `docker-compose.yml` and set in TorrServer (`PeersListenPort`) via `configure.ps1`. It can be changed in `.env` (`TORRSERVER_PEER_PORT`).

2. **Port forwarding on the router (required for WAN).** Go to your router settings → **Port Forwarding / Virtual server** and add a rule:
   - External port: `42116`, protocol: **TCP and UDP**
   - Internal IP: your PC's IP (e.g. `192.168.1.165`), internal port: `42116`

3. **Windows Firewall.** Allow inbound traffic on `42116` (one time, in PowerShell as administrator):
   ```powershell
   New-NetFirewallRule -DisplayName "TorrServer P2P" -Direction Inbound `
     -LocalPort 42116 -Protocol TCP -Action Allow
   New-NetFirewallRule -DisplayName "TorrServer P2P UDP" -Direction Inbound `
     -LocalPort 42116 -Protocol UDP -Action Allow
   ```

4. **Restart when changing the port:** new ports require recreating the container, not just a restart:
   ```powershell
   docker compose up -d torrserver
   ```

**Other levers (as needed):**
- **ISP throttling torrents?** Some providers slow down P2P. In the TorrServer web interface you can enable protocol encryption (`ForceEncrypt`) — sometimes it bypasses throttling (but slightly reduces the peer pool).
- **DHT / PEX / uTP** are already enabled — they provide additional peers beyond the tracker list. Don't disable them.
- **The main thing that can't be fixed with settings:** the number of seeders on a torrent. Choose releases with a high S — this determines the speed ceiling (see FAQ).

> To verify that port forwarding works: in the TorrServer web interface during download, the number of *active peers* should grow, not just *pending*.

### Hide your IP via Cloudflare WARP (without a paid VPN)

If you're behind a "gray" IP (CGNAT) or just want peers to see an IP other than yours — all TorrServer traffic can be routed through the free **Cloudflare WARP** (the `warp` service based on [gluetun](https://github.com/qdm12/gluetun) in `docker-compose.yml`). Tested: P2P through the tunnel works, and speed on well-seeded torrents doesn't suffer.

**What it does / doesn't do:**
- ✅ Peers see Cloudflare's IP, not yours.
- ✅ Can bypass BitTorrent throttling by your provider.
- ❌ Does **not** speed things up on its own and does **not** give you an incoming port (you're behind Cloudflare's NAT) — the speed ceiling is determined by the number of seeders.
- ⚠️ Cloudflare may throttle P2P — if the speed drops to zero, it's worth turning off the tunnel.

**Setup (one time):**
1. Generate a WARP profile (creates a free account):
   ```powershell
   docker run --rm -v "${PWD}\warp:/data" -w //data alpine sh -c `
     "apk add --no-cache curl >/dev/null && curl -sL -o wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 && chmod +x wgcf && ./wgcf register --accept-tos && ./wgcf generate && cat wgcf-profile.conf"
   ```
2. From the output, take the `PrivateKey` and the first `Address` and write them into `.env`:
   ```
   WARP_PRIVATE_KEY=<PrivateKey>
   WARP_ADDRESS_V4=172.16.0.2/32
   ```
3. Bring up the stack: `docker compose up -d`
4. Verify that the IP changed to Cloudflare: `docker exec warp wget -qO- https://api.ipify.org`

**Disable the tunnel:** in `docker-compose.yml` remove `network_mode: "service:warp"` from `torrserver`, restore its own `ports:` block (8090 + 42116) and delete the `warp` service.

> The `warp/` folder (contains account keys) and `.env` are in `.gitignore` and don't go into git.

---

## 🎬 Bitrates and required speed (720p → 4K)

Bitrate is how much data per second the video contains. For streaming through TorrServer it means one thing: **what download speed the seeders must provide so the movie doesn't buffer**. If a release's bitrate is higher than what the seeders provide — there will be buffering, no matter how fast your internet is.

| Quality | Codec | Optimal bitrate | Need ↓ | Size (~2 hrs) |
|---|---|---|---|---|
| **720p** | H.265 (HEVC) | ~4 Mbit/s (3–6) | ~0.5 MB/s | ~4 GB |
| **720p** | H.264 | ~6 Mbit/s (4–8) | ~0.75 MB/s | ~5 GB |
| **1080p** | H.265 (HEVC) | ~8 Mbit/s (6–12) | ~1 MB/s | ~7 GB |
| **1080p** WEB-DL | H.264 | ~12 Mbit/s (8–15) | ~1.5 MB/s | ~11 GB |
| **1080p** BluRay | H.264 | ~28 Mbit/s (20–40) | ~3.5 MB/s | ~22 GB |
| **1440p (2K)** | H.265 (HEVC) | ~16 Mbit/s (12–24) | ~2 MB/s | ~14 GB |
| **4K (2160p)** WEB-DL | HEVC | ~35 Mbit/s (25–50) | ~4.5 MB/s | ~30 GB |
| **4K (2160p)** BluRay/UHD | HEVC | ~65 Mbit/s (50–90) | ~8 MB/s | ~55 GB |
| **4K Remux** | HEVC (uncompressed) | ~100 Mbit/s (80–120+) | ~12.5 MB/s | ~80 GB |

**How to read the table:**
- The values are the total bitrate (video + audio), approximate. HDR, 60 fps and dynamic scenes shift it toward the upper limit.
- **"Need ↓"** is the minimum stable download speed. You need **seeders capable of holding it**, not just a fast plan. For example, 4K Remux requires ~12 MB/s — if a torrent has 2 seeders at 0.1 MB/s each, it will lag even on a 300 Mbit/s connection.
- **H.265 (HEVC)** delivers the same quality at half the bitrate of H.264 — but old/weak devices may not be able to handle it.
- **The sweet spot for Smart TVs (Samsung/LG):** **1080p WEB-DL H.264** — a moderate bitrate, compatible audio (AAC), plenty of seeders. Only pick 4K Remux when there are hundreds of seeders and the player definitely handles the format.

---

## 🔍 Monitoring and logs (PowerShell)

All commands work from any folder — Docker finds containers by name (`jackett`, `torrserver`).

### Jackett logs (search / parser)
```powershell
docker logs jackett --tail 50          # last 50 lines
docker logs jackett -f                 # live, in real time (Ctrl+C to exit)
docker logs jackett --since 10m        # only the last 10 minutes
docker logs jackett -f --timestamps    # live + timestamp on each line
```

### TorrServer logs (playback / download)
```powershell
docker logs torrserver --tail 50
docker logs torrserver -f
```

### Filter logs (grep equivalent)
```powershell
docker logs jackett --tail 200 | Select-String "Error"            # errors only
docker logs jackett --tail 200 | Select-String "search"           # search only
docker logs jackett --tail 200 | Select-String "Error","Found"    # multiple words
```

### Torrent speed and seeders without the web interface
```powershell
# list of active torrents + their hashes
Invoke-RestMethod -Uri "http://127.0.0.1:8090/torrents" -Method Post `
  -ContentType 'application/json' -Body '{"action":"list"}' | Select-Object title, hash

# speed/seeders of a specific torrent (substitute your hash from the list above)
$h = "PUT_YOUR_HASH_HERE"
$t = Invoke-RestMethod -Uri "http://127.0.0.1:8090/torrents" -Method Post `
  -ContentType 'application/json' -Body (@{action='get';hash=$h}|ConvertTo-Json)
"{0} MB/s ↓ | {1} seeders | {2} peers" -f `
  [math]::Round($t.download_speed/1MB,2), $t.connected_seeders, $t.active_peers
```

### Cheat sheet
| I want | Command |
|---|---|
| Fresh logs | `docker logs jackett --tail 50` |
| Watch live | `docker logs jackett -f` |
| What's running now | `docker ps` |
| Restart | `docker restart jackett` |

> 💡 The most convenient way to diagnose the TV: keep `docker logs jackett -f` open and run a search on the TV — you'll immediately see whether the request arrives and what Jackett responds.

---

## 💡 Frequently Asked Questions (FAQ) and troubleshooting

### 1. No sound during playback (BDRip / Blu-Ray)
- **Cause:** Large torrents in BDRip/Remux quality use multichannel audio formats (**AC3 / DTS**). Built-in players in browsers, WebOS and Tizen often lack a license to play them, so the video plays without sound.
- **Solution:**
  - On PC: Use an external player (VLC, PotPlayer), choosing the "Open in VLC" option in Lampa.
  - On Smart TV (Android): Install Vimu Media Player, MX Player or VLC and select it in Lampa settings (Settings -> Player).
  - On Samsung/LG TVs: For viewing, choose torrents in the **WEB-DL** / **WEBRip** format (they usually have compatible AAC audio).

### 2. Why is the speed shown as 30 MB/s if my plan is 300 Mbit/s?
- Pay attention to the units of measurement: providers state speed in Mega**bits** (Mbit/s), while Lampa or TorrServer often show it in Mega**bytes** (MB/s).
- Since 1 Byte = 8 bits, a speed of 33 MB/s actually equals ~265 Mbit/s. This means the program is working at its maximum!

### 3. The download speed doesn't reach its maximum but "jumps"
- Torrent (BitTorrent) is a P2P network. The speed depends on the number of ordinary people (seeders) currently sharing this file, and their upload speed.
- TorrServer also "smartly" lowers the speed when the cache fills up, to avoid overloading the computer. The movie isn't downloaded fully, only buffered on the fly.

### 4. What happens to the movie if I reboot the computer?
- If you reboot the PC (running the server) during viewing, the movie on the TV will freeze. Since TorrServer caches video only in RAM (to avoid wearing out the hard drive), after a PC restart the cache will be cleared.
- **How to continue:** Just start the movie on the TV again and rewind to the desired minute. TorrServer will instantly connect to seeders and continue downloading from exactly that moment (usually this takes 3-5 seconds).

### 5. The movie suddenly freezes, and after reconnecting a long hash appears instead of the title
- **Cause:** TorrServer periodically crashed due to a defect in TorrServer MatriX.142 itself (open bug [YouROK/TorrServer#766](https://github.com/YouROK/TorrServer/issues/766) — a data race in the torrent library under parallel load). Docker automatically restarts the service in ~5 seconds; while Lampa re-fetches the torrent's metadata, it shows its infohash — this is temporary.
- **Solution (already applied in this repository):** the TorrServer version is pinned to the stable `MatriX.141.10` via the `ghcr.io/yourok/torrserver` image (the tag is set by the `TORRSERVER_VERSION` variable in `.env`). Do **not** use the `yourok/torrserver:latest` image — on every start it downloads the newest binary from GitHub, meaning the version is uncontrolled.
- When bug #766 is fixed — just raise `TORRSERVER_VERSION` in `.env` and run `docker compose up -d torrserver`.
- Check the current version: `Invoke-RestMethod http://127.0.0.1:8090/echo`. Data/settings are now stored in `torrserver_data/` and survive container recreation.

### 6. Lampa on the TV says "parser not responding", even though the `:9117` page opens from a phone
This is almost always one of two causes (the page opens from a phone because that's ordinary browser navigation, while Lampa makes background JS requests to which different security rules apply):

1. **CORS is disabled in Jackett.** The browser blocks Jackett's response because the request comes from a foreign domain (`lampa.mx`).
   - **Solution:** in the file `jackett_config/Jackett/ServerConfig.json` set `"AllowCORS": true` and restart the container: `docker restart jackett`.
2. **Mixed content (HTTPS → HTTP).** If Lampa is opened over `https://` while Jackett runs over `http://`, the TV browser blocks the "insecure" request.
   - **Solution:** in Media Station X, in the *Start Parameter* field, specify Lampa over **http** (`http://lampa.mx`), so that both Lampa and Jackett are over HTTP.

Also check that:
- Lampa has the PC's LAN IP specified, not `localhost`: `http://192.168.1.165:9117` (find your IP: `ipconfig` → the IPv4 line).
- The TV and PC are on the **same network** (without "guest" Wi-Fi or AP isolation).
- Windows Firewall allows inbound traffic on port `9117` for the private network.

# 🎬 Step-by-step "from scratch" guide

<p align="center">
  <a href="GETTING-STARTED.md"><img src="assets/lang-ua.svg" alt="Українська" height="28"></a>
  <a href="GETTING-STARTED.ru.md"><img src="assets/lang-ru.svg" alt="Русский (СНД)" height="28"></a>
  <a href="GETTING-STARTED.en.md"><img src="assets/lang-en.svg" alt="English" height="28"></a>
</p>

This guide takes you from an empty computer to a movie on your screen — **even if you've never heard the word "Docker"**.

The guide is split into two parts:

- **[PART 1 — Using it on a PC](#part-1--using-it-on-a-pc)** — the simplest. Watch movies on the computer itself. You don't need to know anything about networking, IP addresses or TV setup.
- **[PART 2 — As a server for TV and Android](#part-2--as-a-server-for-tv-and-android)** — the continuation. Turn your computer into a home server so you can watch on a TV, set-top box or phone.

> ⏱ Part 1 — ~15 minutes. Part 2 — another ~15 minutes. No technical knowledge required: be able to install programs and copy text.

---

## 📖 What is this, really (in plain words)

Think of it as **your own Netflix that plays movies from torrents**, but with no downloading and no ads. A small "engine" runs on your computer, searching for and playing video on the fly — nothing is saved to disk.

Three components:
- **TorrServer** — the "engine" that turns a torrent into a video stream.
- **Jackett** — the "search engine" across torrent sites.
- **FlareSolverr** — a helper that bypasses Cloudflare protection on trackers (so more sites work).

You control everything through the **Lampa** app — a nice catalog with posters.

> ℹ️ **Important about Lampa (from the official developer FAQ):** Lampa is not a finished solution but a **"construction kit" (skeleton)** that you must **configure yourself** (specify your TorrServer and parser — which is exactly what we do below). It's a separate free app, available natively almost everywhere:
> - **PC:** [Lampa Desktop](https://github.com/Kolovatoff/lampa-desktop/releases) (Windows/Mac/Linux)
> - **Android / Android TV / set-top boxes:** [official lampa-app/LAMPA releases](https://github.com/lampa-app/LAMPA/releases)
> - **Web / Smart TV:** the [lampa.mx](https://lampa.mx) site
> - **Source / self-hosting:** [yumata/lampa](https://github.com/yumata/lampa)

---

## 💻 What you'll need

| Requirement | Minimum | Comfortable |
|---|---|---|
| System | Windows 10/11 (64-bit), or Linux/Mac | Windows 11 |
| RAM | 8 GB | 16 GB+ |
| Disk space | ~2 GB for programs | — |
| Internet | any | wired, 100+ Mbit/s |

> 💡 The movie cache is held in **RAM**, not on disk — the disk doesn't wear out.

---
---

# PART 1 — Using it on a PC

> 🎯 Goal of this part: install everything and watch movies **on this same computer**. No network setup — everything via the `localhost` address (that is, "this computer").

> ⚡ **Easiest path (recommended):** do only **Step 1** (Docker) and **Step 2** (download), then run the installer — it does Steps 3–4 for you:
> - **Windows:** in the `media-server` folder, double-click **`install.bat`**.
> - **Linux / Mac:** `cd media-server && bash install.sh`
>
> In the menu, tick the trackers you want (and optionally IP hiding). The installer brings up the server, configures Jackett, **reads the API key for you** and prints it at the end — copy it for Step 5. Then jump straight to **Step 5**. Want full manual control — do Steps 3–4 below.

## Step 1. Install Docker Desktop

"Docker" is a program that runs our media server in an isolated "container". It installs like a normal app.

1. Open [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/) → **Download for Windows**.
2. Run the file, click **OK / Next** to the end, allow a reboot if needed.
3. Launch **Docker Desktop** (the whale icon 🐳). Wait until the whale at the bottom-left turns green — "ready".

> ⚠️ If Docker asks to fix "WSL 2" — it will show a button itself. Click it and reboot.

## Step 2. Download this project

1. On the project's GitHub page → the green **`< > Code` → Download ZIP** button.
2. Unpack it, for example, into `C:\media-server`.

## Step 3. First run

1. Open the **`media-server`** subfolder.
2. In an empty spot inside the folder: **Shift + right mouse button** → **"Open PowerShell window here"**.
3. Type and press **Enter**:
   ```powershell
   docker compose up -d
   ```
4. The first time, the components download for a few minutes. When you see `Started` lines — the server is running. 🎉

**Check:** open [http://localhost:9117](http://localhost:9117) — Jackett should open.

## Step 4. Set up search (Jackett)

Here you tell the server which sites to search for movies. Everything is done on the Jackett dashboard: **[http://localhost:9117/UI/Dashboard](http://localhost:9117/UI/Dashboard)**

1. **Copy the API Key** — the long string in the top-right corner. You'll need it later.
2. **Add a tracker:** the **`+ Add indexer`** button → find the one you need (e.g. `Toloka`, `The Pirate Bay`, `1337x`) → click the yellow **`+`**.
   - Public ones (PirateBay, 1337x) are added right away.
   - Private ones (Toloka) will ask for your **login and password** for that site.
   - 💪 Thanks to the built-in FlareSolverr, even trackers with Cloudflare protection work (1337x, etc.).
3. **Remove/edit a tracker:** on the same dashboard, next to each added tracker there are icons — trash can (remove), wrench (configure), magnifier (test).

> 💡 You can automate adding private trackers and server optimization with the `configure.ps1` script — see the [technical README](README.en.md).

## Step 5. Watch on the PC 🍿

**The recommended way is the native [Lampa Desktop](https://github.com/Kolovatoff/lampa-desktop/releases) app** (Windows/Mac/Linux). It's more reliable than a browser: it remembers settings, has no problems with blocked "insecure" requests, and easily connects external players.

1. Download and install Lampa Desktop from the [releases](https://github.com/Kolovatoff/lampa-desktop/releases).
2. In **Settings**, specify two "local" addresses:
   - **TorrServer** (Settings → Torrents): `http://localhost:8090`
   - **Jackett / Parser** (Settings → Parser): the link `http://localhost:9117` + the **API Key** from Step 4.
3. Find a movie → **"Watch"** → pick a release (the more **seeders**, the faster) → playback in a few seconds.

> 💡 **A quick alternative without installing:** open [lampa.mx](https://lampa.mx) right in the browser and enter the same addresses. It works, but the browser may block requests to `localhost` from an HTTPS site — then either allow "insecure content" in the site settings, or use the desktop app above.
>
> If the video won't play because of the format — open the stream in **VLC** ("Open in external player") or via the TorrServer web interface: [http://localhost:8090](http://localhost:8090).

**Done! Everything works on the computer.** If that's enough — you can stop here. Want to watch on a TV — move on to Part 2. 👇

---
---

# PART 2 — As a server for TV and Android

> 🎯 Goal: turn the computer into a **home server** so you can watch movies on a TV, set-top box or phone. The computer does all the work, the other devices only display.

**What changes compared to Part 1:** instead of `localhost` you now need to specify the **computer's real address on the network**, and also allow connections in the firewall.

### ⚠️ The main condition
The computer and the TV must be **on the same home network** (one router/Wi-Fi). And the computer must be **turned on while you watch**.

---

## Step 6. Find the computer's address

1. In the PowerShell window, type:
   ```powershell
   ipconfig
   ```
2. Find the **"IPv4 Address"** line — something like `192.168.1.165`.
3. Write this number down. **This is your server's address** for all devices.

> 💡 So the address doesn't change after a reboot, "pin" it to the computer in your router settings (Static DHCP / reservation). Not required, but convenient.

## Step 7. Allow connections in the firewall

By default, Windows may block incoming connections from other devices. Allow the server ports — in PowerShell **as administrator**:

```powershell
New-NetFirewallRule -DisplayName "MediaServer TorrServer" -Direction Inbound -LocalPort 8090 -Protocol TCP -Action Allow
New-NetFirewallRule -DisplayName "MediaServer Jackett"    -Direction Inbound -LocalPort 9117 -Protocol TCP -Action Allow
```

> How to open PowerShell as administrator: Start menu → type "PowerShell" → right-click → "Run as administrator".

## Step 8. Install Lampa on the TV

### 🤖 Android TV / set-top box (recommended way — via Downloader)
The most convenient is the **Downloader** app, which installs both Lampa and the Vimu player from a single code. ([Official Lampa developer guide](https://telegra.ph/Ustanovka-prilozhenij-Lampa-Torrserve-Matrix-Vimu-na-Android-TV-s-pomoshchyu-Downloader-11-18))

1. **Install Downloader.** In **Google Play** on the TV, find **Downloader by AFTVnews** (orange icon with an arrow) → **Install**.
2. **Open the right page.** Launch Downloader → in the code field enter:
   ```
   4384169
   ```
   → press **Go / OK**. The "APK download" page opens.
3. **Choose the app** from the list and press **OK → Download**:
   - 📺 **Lampa** — required (the app itself)
   - ▶️ **Vimu Media Player** — recommended (external player for DTS/4K, fixes sound issues)
   - 🧲 Torrserve MatriX — **not needed**: TorrServer already runs on your PC (see below).
4. After downloading, press **Install**.
5. **If the TV blocks the install** ("Your TV blocks unknown apps…") → **Settings** → allow installation for **Downloader** → go back and press Install again.

> 💡 **Don't install TorrServer on the TV.** Your server already runs on the PC — the TV only needs **Lampa** (the interface) and **Vimu** (the player). In Step 9 you'll simply point Lampa at your PC's address.

### 📺 Samsung (Tizen) — via Media Station X
Downloader **doesn't work** on Samsung (Tizen isn't Android). So for Samsung:
1. In the **Samsung Apps** store, install **Media Station X**.
2. Launch it → **Settings → Start Parameter → Setup**.
3. Enter `lampa.mx`, confirm. The app will restart and open Lampa.

### 📺 LG (WebOS)
Via the browser at [lampa.mx](https://lampa.mx) or the available Lampa launchers (see the WebOS community).

> 📚 **Official Lampa guides (from the developers):** [setup from scratch](https://telegra.ph/Nastraivaem-Lampu-s-nulya-06-18) · [GitHub wiki](https://github.com/yumata/lampa/wiki) · [installing on LG / Samsung / Hisense (Vidaa)](https://telegra.ph/USTANOVKA-i-zapusk-na-Lg-Samsung-Hisense-Vidaa-MCX-01-02) · [community](https://t.me/lampa_group). The full list of resources is in the [technical README](README.en.md).

## Step 9. Connect Lampa to the server

In Lampa on the TV, enter the addresses — **now with the real IP instead of localhost**:

### TorrServer (playback)
**Settings → Torrents** → enable TorrServer → main link:
```
http://YOUR_ADDRESS:8090
```
For example: `http://192.168.1.165:8090`

### Jackett (search)
**Settings → Parser** → enable → enter:
- **Link:** `http://YOUR_ADDRESS:9117` (e.g. `http://192.168.1.165:9117`)
- **API key:** the same string from the Jackett Dashboard (Step 4).

> 📌 Remember: **8090** — viewing, **9117** — search. Don't mix up the ports.

## Step 10. Watch on the TV 🍿

Find a movie → **"Watch"** → pick a release with more **seeders** → enjoy.

## Step 11. Autostart (so you don't launch it manually)

To make the server start together with the computer:
- **Docker Desktop → ⚙️ Settings → General →** the **"Start Docker Desktop when you log in"** checkbox.
- The containers have `restart: unless-stopped`, so they come up automatically.

After a computer restart, run `configure.ps1` once (or check the settings) — details in the [README](README.en.md).

---

## ❓ If something doesn't work

| Problem | Quick fix |
|---|---|
| Lampa on the TV says "parser not responding" | Check the Jackett address (`:9117`) and the firewall (Step 7). Details — FAQ #6 in the [README](README.en.md) |
| Video won't start | Check the TorrServer address (`:8090`) and that the TV is on the same network |
| No sound | Pick a **WEB-DL** release instead of BDRemux, or an external player (VLC/Vimu) — FAQ #1 |
| Slow | Pick a torrent with more seeders |
| No subtitles | Pick the **Full** track, not **Forced** — FAQ in the README |

📚 **The full list of fixes, speed optimization, hiding your IP via WARP and the quality table** — in the [technical README](README.en.md).

---

## 🔒 I want to hide my IP address

The project can route torrent traffic through the free **Cloudflare WARP** tunnel so other participants see an address other than yours. Optional, but available. The easiest way is to enable WARP with a checkbox in the installer (see "Easiest path" at the start of Part 1); details are in the "WARP" section of the [README](README.en.md).

---

*Enjoy watching! If the guide is unclear somewhere — open an [issue on GitHub](../../issues).*

#!/usr/bin/env bash
# ============================================================================
#  TV_Server — guided installer (Linux / NAS / Raspberry Pi)
#
#  One command sets everything up:
#    * pick components with a checkbox menu (WARP IP-hiding, private trackers);
#    * generates .env for you;
#    * brings up the Docker stack;
#    * auto-reads the Jackett API key (no copy-paste);
#    * auto-enables CORS + links FlareSolverr (fixes "parser not responding");
#    * tunes TorrServer (RAM cache, connection limit, fixed peer port);
#    * prints ready-to-paste Lampa URLs with your LAN IP.
#
#  Usage:  bash install.sh        (run from the media-server/ folder)
#  Safe to re-run — it's idempotent.
# ============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# --- Tracker registry (mirror of configure.ps1) -----------------------------
# tag|Label|site|USER_VAR|PASS_VAR
TRACKERS=(
  "toloka|Toloka.to|https://toloka.to/|TOLOKA_USER|TOLOKA_PASS"
  "rutracker|RuTracker.org|https://rutracker.org/|RUTRACKER_USER|RUTRACKER_PASS"
)

C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_DIM=$'\e[90m'; C_OFF=$'\e[0m'
say()  { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '  %s+ %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- Preflight --------------------------------------------------------------
have docker || die "Docker not found. Install Docker first: https://docs.docker.com/engine/install/"
if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif have docker-compose; then
  DC=(docker-compose)
else
  die "Docker Compose not found. Install the compose plugin: https://docs.docker.com/compose/install/"
fi
have python3 || die "python3 not found — needed for API setup. Install it (e.g. apt install python3)."

USE_WHIPTAIL=0
if have whiptail; then USE_WHIPTAIL=1; fi

# --- Component selection ----------------------------------------------------
WANT_WARP=0
declare -a SELECTED_TRACKERS=()

if [ "$USE_WHIPTAIL" -eq 1 ]; then
  items=( "warp" "Hide IP for P2P (Cloudflare WARP)" "OFF" )
  for t in "${TRACKERS[@]}"; do IFS='|' read -r tag label _ _ _ <<<"$t"; items+=( "$tag" "$label (private tracker)" "OFF" ); done
  chosen=$(whiptail --title "TV_Server installer" --checklist \
    "Space = toggle, Enter = confirm.\nCore (TorrServer + Jackett + FlareSolverr) is always installed." \
    16 64 "$(( ${#items[@]} / 3 ))" "${items[@]}" 3>&1 1>&2 2>&3) || die "Cancelled."
  for tag in $chosen; do
    tag=${tag//\"/}
    [ "$tag" = "warp" ] && WANT_WARP=1 || SELECTED_TRACKERS+=( "$tag" )
  done
else
  warn "whiptail not installed — using a plain prompt instead."
  read -r -p "Hide your IP for P2P via Cloudflare WARP? [y/N] " a; [[ "${a,,}" == y* ]] && WANT_WARP=1
  for t in "${TRACKERS[@]}"; do
    IFS='|' read -r tag label _ _ _ <<<"$t"
    read -r -p "Configure $label? [y/N] " a; [[ "${a,,}" == y* ]] && SELECTED_TRACKERS+=( "$tag" )
  done
fi

# --- Collect credentials ----------------------------------------------------
declare -A CRED
ask_secret() { # prompt -> echoes value
  local prompt="$1" val
  if [ "$USE_WHIPTAIL" -eq 1 ]; then
    val=$(whiptail --title "TV_Server installer" --passwordbox "$prompt" 9 60 3>&1 1>&2 2>&3) || val=""
  else
    read -r -s -p "$prompt " val; echo >&2
  fi
  printf '%s' "$val"
}
ask_text() {
  local prompt="$1" val
  if [ "$USE_WHIPTAIL" -eq 1 ]; then
    val=$(whiptail --title "TV_Server installer" --inputbox "$prompt" 9 60 3>&1 1>&2 2>&3) || val=""
  else
    read -r -p "$prompt " val
  fi
  printf '%s' "$val"
}

for t in "${TRACKERS[@]}"; do
  IFS='|' read -r tag label _ uvar pvar <<<"$t"
  for s in "${SELECTED_TRACKERS[@]:-}"; do
    if [ "$s" = "$tag" ]; then
      CRED[$uvar]=$(ask_text "$label — username / e-mail:")
      CRED[$pvar]=$(ask_secret "$label — password:")
    fi
  done
done

# --- WARP profile -----------------------------------------------------------
WARP_KEY=""; WARP_ADDR="172.16.0.2/32"
if [ "$WANT_WARP" -eq 1 ]; then
  say "Generating a free Cloudflare WARP profile..."
  if profile=$(docker run --rm alpine sh -c \
      'apk add --no-cache curl >/dev/null 2>&1 && curl -sL -o /wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 && chmod +x /wgcf && cd /tmp && /wgcf register --accept-tos >/dev/null 2>&1 && /wgcf generate >/dev/null 2>&1 && cat wgcf-profile.conf' 2>/dev/null); then
    WARP_KEY=$(printf '%s\n' "$profile" | awk -F' *= *' '/PrivateKey/{print $2; exit}')
    WARP_ADDR=$(printf '%s\n' "$profile" | awk -F' *= *' '/Address/{print $2; exit}')
    [ -n "$WARP_KEY" ] && ok "WARP profile generated." || warn "Could not parse WARP profile — fill WARP_PRIVATE_KEY in .env manually."
  else
    warn "WARP profile generation failed (arch/network). You can set WARP keys in .env later."
  fi
fi

# --- Write .env -------------------------------------------------------------
say "Writing .env..."
export WARP_KEY WARP_ADDR
CRED_TOLOKA_USER="${CRED[TOLOKA_USER]:-}" CRED_TOLOKA_PASS="${CRED[TOLOKA_PASS]:-}" \
CRED_RUTRACKER_USER="${CRED[RUTRACKER_USER]:-}" CRED_RUTRACKER_PASS="${CRED[RUTRACKER_PASS]:-}" \
python3 - <<'PY'
import os, re
src = ".env" if os.path.exists(".env") else ".env.example"
with open(src, encoding="utf-8") as f:
    text = f.read()
over = {
    "TOLOKA_USER": os.environ.get("CRED_TOLOKA_USER",""),
    "TOLOKA_PASS": os.environ.get("CRED_TOLOKA_PASS",""),
    "RUTRACKER_USER": os.environ.get("CRED_RUTRACKER_USER",""),
    "RUTRACKER_PASS": os.environ.get("CRED_RUTRACKER_PASS",""),
    "WARP_PRIVATE_KEY": os.environ.get("WARP_KEY",""),
    "WARP_ADDRESS_V4": os.environ.get("WARP_ADDR","") or "172.16.0.2/32",
}
for k, v in over.items():
    if v == "" and re.search(rf'(?m)^{k}=.+', text):
        continue  # don't wipe an existing value with a blank answer
    if re.search(rf'(?m)^{k}=', text):
        text = re.sub(rf'(?m)^{k}=.*$', f'{k}={v}', text)
    else:
        text += f'\n{k}={v}\n'
with open(".env", "w", encoding="utf-8") as f:
    f.write(text)
print("  .env ready")
PY

# --- Bring up the stack -----------------------------------------------------
COMPOSE_FILE="docker-compose.yml"
[ "$WANT_WARP" -eq 1 ] && COMPOSE_FILE="docker-compose.warp.yml"
say "Starting containers ($COMPOSE_FILE)..."
"${DC[@]}" -f "$COMPOSE_FILE" up -d

# --- Wait for Jackett -------------------------------------------------------
say "Waiting for Jackett..."
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:9117"; then break; fi
  sleep 2
done

CFG="jackett_config/Jackett/ServerConfig.json"
for _ in $(seq 1 15); do [ -f "$CFG" ] && break; sleep 2; done

# --- Auto-read API key + patch CORS/FlareSolverr ----------------------------
say "Configuring Jackett..."
APIKEY=$(FS_URL="http://flaresolverr:8191" python3 - "$CFG" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8-sig") as f: cfg = json.load(f)
except Exception:
    print(""); sys.exit(0)
changed = False
if not cfg.get("AllowCORS"): cfg["AllowCORS"] = True; changed = True
if cfg.get("FlareSolverrUrl") != os.environ["FS_URL"]:
    cfg["FlareSolverrUrl"] = os.environ["FS_URL"]; changed = True
if changed:
    with open(path, "w", encoding="utf-8") as f: json.dump(cfg, f, indent=2)
print(cfg.get("APIKey",""))
PY
) || APIKEY=""
if [ -n "$APIKEY" ]; then
  ok "API key read automatically; CORS + FlareSolverr linked."
  python3 - "$APIKEY" <<'PY'
import os, re, sys
key = sys.argv[1]
with open(".env", encoding="utf-8") as f: t = f.read()
t = re.sub(r'(?m)^JACKETT_APIKEY=.*$', f'JACKETT_APIKEY={key}', t) if re.search(r'(?m)^JACKETT_APIKEY=', t) else t + f'\nJACKETT_APIKEY={key}\n'
open(".env","w",encoding="utf-8").write(t)
PY
  "${DC[@]}" -f "$COMPOSE_FILE" restart jackett >/dev/null 2>&1 || true
else
  warn "Could not read Jackett API key yet — open http://localhost:9117 and re-run to finish tracker setup."
fi

# --- Tune TorrServer --------------------------------------------------------
say "Tuning TorrServer..."
python3 - <<'PY' || echo "  ! TorrServer not reachable yet — re-run later to tune."
import json, urllib.request
base = "http://127.0.0.1:8090"
def call(path, payload):
    req = urllib.request.Request(base+path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type":"application/json"})
    return urllib.request.urlopen(req, timeout=8)
cur = json.load(call("/settings", {"action":"get"}))
cur.update(CacheSize=2147483648, ConnectionsLimit=1000,
           PeersListenPort=42116, TorrentDisconnectTimeout=3600)
call("/settings", {"action":"set","sets":cur}).read()
print("  + cache 2 GiB, 1000 connections, peer port 42116")
PY

# --- Configure selected trackers -------------------------------------------
if [ -n "$APIKEY" ] && [ "${#SELECTED_TRACKERS[@]:-0}" -gt 0 ]; then
  say "Adding trackers to Jackett..."
  for t in "${TRACKERS[@]}"; do
    IFS='|' read -r tag label site uvar pvar <<<"$t"
    for s in "${SELECTED_TRACKERS[@]}"; do
      [ "$s" = "$tag" ] || continue
      u="${CRED[$uvar]:-}"; p="${CRED[$pvar]:-}"
      [ -z "$u" ] && { warn "$label: no username, skipped"; continue; }
      body=$(printf '[{"id":"sitelink","value":"%s"},{"id":"username","value":"%s"},{"id":"password","value":"%s"}]' "$site" "$u" "$p")
      if curl -fsS -o /dev/null -X POST -H "Content-Type: application/json" \
           --data "$body" "http://127.0.0.1:9117/api/v2.0/indexers/$tag/config?apikey=$APIKEY"; then
        ok "$label configured"
      else
        warn "$label failed (check credentials in the Jackett UI)"
      fi
    done
  done
fi

# --- Summary ----------------------------------------------------------------
LAN_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
[ -z "${LAN_IP:-}" ] && LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "${LAN_IP:-}" ] && LAN_IP="<PC-IP>"

echo
say "Done. Point Lampa at your server:"
printf '  %sTorrServer:%s http://%s:8090\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
printf '  %sJackett   :%s http://%s:9117   (API key already applied)\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
if [ "$WANT_WARP" -eq 1 ]; then
  printf '  %sIP hiding :%s ON — verify with: docker exec warp wget -qO- https://api.ipify.org\n' "$C_GREEN" "$C_OFF"
fi
printf '%s  Reminder: for WAN access, forward TCP+UDP port 42116 on your router.%s\n' "$C_DIM" "$C_OFF"

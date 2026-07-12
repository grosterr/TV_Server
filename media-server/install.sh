#!/usr/bin/env bash
# ============================================================================
#  TV_Server — guided installer (Linux / NAS / Raspberry Pi)
#
#  Fresh install: pick components (WARP IP-hiding, private trackers) with a
#  checkbox menu, generate .env, bring up the stack, auto-read the Jackett API
#  key, enable CORS + link FlareSolverr, tune TorrServer, print Lampa URLs.
#
#  If a server is already installed here, it instead offers:
#     REPAIR  — re-apply config and restart the stack (reuses your .env)
#     DELETE  — stop and remove containers, volumes and data
#     QUIT    — exit without changes
#
#  Usage:  bash install.sh        (run from the media-server/ folder)
#  Safe to re-run — it's idempotent.
#
#  Non-interactive (CI / automation): NONINTERACTIVE=1, optionally ACTION=
#  install|repair|delete (delete needs FORCE=1). Drive a fresh install via env:
#    NONINTERACTIVE=1 WANT_WARP=0 SELECT_TRACKERS="toloka" \
#      TOLOKA_USER=me TOLOKA_PASS=secret bash install.sh
# ============================================================================
set -Eeuo pipefail
trap 'printf "\e[31mInstaller aborted (line %s).\e[0m\n" "$LINENO" >&2' ERR

cd "$(dirname "$(readlink -f "$0")")" || exit 1

HELPER=(python3 lib/setup_helpers.py)
COMPOSE_FILE="docker-compose.yml"

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
have docker  || die "Docker not found. Install Docker first: https://docs.docker.com/engine/install/"
have curl    || die "curl not found — needed for setup. Install it (e.g. apt install curl)."
have python3 || die "python3 not found — needed for setup. Install it (e.g. apt install python3)."
if docker compose version >/dev/null 2>&1; then DC=(docker compose)
elif have docker-compose; then DC=(docker-compose)
else die "Docker Compose not found. Install the compose plugin: https://docs.docker.com/compose/install/"; fi
docker info >/dev/null 2>&1 || die "Docker is installed but the daemon isn't running. Start Docker and retry."

NONINTERACTIVE="${NONINTERACTIVE:-0}"
USE_WHIPTAIL=0
if [ "$NONINTERACTIVE" != "1" ] && have whiptail; then USE_WHIPTAIL=1; fi

WANT_WARP="${WANT_WARP:-0}"
declare -a SELECTED_TRACKERS=()
declare -A CRED

# --- Helpers ----------------------------------------------------------------
get_env() { [ -f .env ] && grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

is_installed() {
  [ -f .env ] && return 0
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^(torrserver|jackett|flaresolverr|warp)$' && return 0
  return 1
}

do_delete() {
  if [ "$NONINTERACTIVE" = "1" ]; then
    [ "${FORCE:-0}" = "1" ] || die "Refusing to DELETE without FORCE=1 in non-interactive mode."
  else
    read -r -p "This removes containers, volumes AND data (jackett_config, torrserver_data, warp, .env). Type 'delete' to confirm: " ans
    [ "$ans" = "delete" ] || { say "Cancelled — nothing removed."; exit 0; }
  fi
  say "Removing the media server..."
  for f in docker-compose.warp.yml docker-compose.yml; do
    "${DC[@]}" -f "$f" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf jackett_config torrserver_data warp .env
  ok "Removed containers, volumes and data. Re-run install.sh to set up again."
}

load_existing_config() {   # REPAIR: reuse choices from the existing .env
  [ -f .env ] || cp .env.example .env
  if [ -n "$(get_env WARP_PRIVATE_KEY)" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx warp; then
    WANT_WARP=1
  fi
  for t in "${TRACKERS[@]}"; do
    IFS='|' read -r tag _ _ uvar pvar <<<"$t"
    local u; u="$(get_env "$uvar")"
    if [ -n "$u" ]; then
      CRED[$uvar]="$u"; CRED[$pvar]="$(get_env "$pvar")"
      SELECTED_TRACKERS+=( "$tag" )
    fi
  done
}

# --- Existing installation? offer REPAIR / DELETE / QUIT --------------------
MODE=install
if is_installed; then
  act="${ACTION:-}"
  if [ -z "$act" ]; then
    if [ "$NONINTERACTIVE" = "1" ]; then
      act=repair
    elif [ "$USE_WHIPTAIL" = "1" ]; then
      act=$(whiptail --title "TV_Server — already installed" --menu \
        "A media server is already set up in this folder. What do you want to do?" 14 62 3 \
        REPAIR "Re-apply config and restart the stack" \
        DELETE "Stop and remove containers + data" \
        QUIT   "Exit without changes" 3>&1 1>&2 2>&3) || act=QUIT
    else
      say "A media server is already installed here."
      read -r -p "[R]epair, [D]elete, or [Q]uit? " a
      case "${a,,}" in r*) act=REPAIR;; d*) act=DELETE;; *) act=QUIT;; esac
    fi
  fi
  case "${act,,}" in
    quit)   say "Nothing to do."; exit 0 ;;
    delete) do_delete; exit 0 ;;
    repair) MODE=repair; say "Repairing existing installation..."; load_existing_config ;;
    *)      MODE=repair; load_existing_config ;;
  esac
fi

# --- Fresh install: component selection + credentials -----------------------
if [ "$MODE" = install ]; then
  if [ "$NONINTERACTIVE" = "1" ]; then
    IFS=', ' read -r -a SELECTED_TRACKERS <<<"${SELECT_TRACKERS:-}"
    say "Non-interactive install (WARP=$WANT_WARP, trackers='${SELECT_TRACKERS:-}')."
  elif [ "$USE_WHIPTAIL" -eq 1 ]; then
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

  ask_secret() { local prompt="$1" val
    if [ "$USE_WHIPTAIL" -eq 1 ]; then val=$(whiptail --title "TV_Server installer" --passwordbox "$prompt" 9 60 3>&1 1>&2 2>&3) || val=""
    else read -r -s -p "$prompt " val; echo >&2; fi
    printf '%s' "$val"
  }
  ask_text() { local prompt="$1" val
    if [ "$USE_WHIPTAIL" -eq 1 ]; then val=$(whiptail --title "TV_Server installer" --inputbox "$prompt" 9 60 3>&1 1>&2 2>&3) || val=""
    else read -r -p "$prompt " val; fi
    printf '%s' "$val"
  }

  for t in "${TRACKERS[@]}"; do
    IFS='|' read -r tag label _ uvar pvar <<<"$t"
    for s in "${SELECTED_TRACKERS[@]:-}"; do
      [ "$s" = "$tag" ] || continue
      if [ "$NONINTERACTIVE" = "1" ]; then CRED[$uvar]="${!uvar:-}"; CRED[$pvar]="${!pvar:-}"
      else CRED[$uvar]=$(ask_text "$label — username / e-mail:"); CRED[$pvar]=$(ask_secret "$label — password:"); fi
    done
  done

  # WARP profile (fresh install only)
  WARP_KEY="${WARP_PRIVATE_KEY:-}"; WARP_ADDR="${WARP_ADDRESS_V4:-172.16.0.2/32}"
  if [ "$WANT_WARP" -eq 1 ] && [ -z "$WARP_KEY" ]; then
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

  say "Writing .env..."
  env_src=".env"; [ -f .env ] || env_src=".env.example"
  "${HELPER[@]}" render-env "$env_src" .env \
    --set "TOLOKA_USER=${CRED[TOLOKA_USER]:-}"       --set "TOLOKA_PASS=${CRED[TOLOKA_PASS]:-}" \
    --set "RUTRACKER_USER=${CRED[RUTRACKER_USER]:-}" --set "RUTRACKER_PASS=${CRED[RUTRACKER_PASS]:-}" \
    --set "WARP_PRIVATE_KEY=${WARP_KEY}"             --set "WARP_ADDRESS_V4=${WARP_ADDR:-172.16.0.2/32}"
  ok ".env ready"
fi

# --- Bring up the stack (fresh install or repair) ---------------------------
[ "$WANT_WARP" -eq 1 ] && COMPOSE_FILE="docker-compose.warp.yml"
# linuxserver/jackett writes its config as PUID:PGID. Match the current user so
# this script can rewrite ServerConfig.json afterward (enable CORS, read key).
export PUID="${PUID:-$(id -u)}" PGID="${PGID:-$(id -g)}"
say "Starting containers ($COMPOSE_FILE)..."
"${DC[@]}" -f "$COMPOSE_FILE" up -d

# --- Wait for Jackett -------------------------------------------------------
say "Waiting for Jackett..."
for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:9117" && break; sleep 2; done
CFG="jackett_config/Jackett/ServerConfig.json"
for _ in $(seq 1 15); do [ -f "$CFG" ] && break; sleep 2; done

# --- Auto-read API key + patch CORS/FlareSolverr ----------------------------
say "Configuring Jackett..."
APIKEY=$("${HELPER[@]}" patch-jackett "$CFG" "http://flaresolverr:8191") || APIKEY=""
if [ -n "$APIKEY" ]; then
  ok "API key read automatically; CORS + FlareSolverr linked."
  "${HELPER[@]}" render-env .env .env --set "JACKETT_APIKEY=$APIKEY"
  "${DC[@]}" -f "$COMPOSE_FILE" restart jackett >/dev/null 2>&1 || true
else
  warn "Could not read Jackett API key yet — open http://localhost:9117 and re-run to finish setup."
fi

# --- Tune TorrServer --------------------------------------------------------
say "Tuning TorrServer..."
"${HELPER[@]}" tune-torrserver "http://127.0.0.1:8090" || warn "TorrServer not reachable yet — re-run later to tune."

# --- Configure selected trackers -------------------------------------------
if [ -n "$APIKEY" ] && [ "${#SELECTED_TRACKERS[@]}" -gt 0 ]; then
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
say "$([ "$MODE" = repair ] && echo "Repaired." || echo "Done.") Point Lampa at your server:"
printf '  %sTorrServer:%s http://%s:8090\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
printf '  %sJackett   :%s http://%s:9117\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
[ -n "${APIKEY:-}" ] && printf '  %sAPI key   :%s %s\n%s  (paste it into Lampa → Parser/Jackett)%s\n' \
  "$C_GREEN" "$C_OFF" "$APIKEY" "$C_DIM" "$C_OFF"
if [ "$WANT_WARP" -eq 1 ]; then
  printf '  %sIP hiding :%s ON — verify with: docker exec warp wget -qO- https://api.ipify.org\n' "$C_GREEN" "$C_OFF"
fi
printf '%s  Reminder: for WAN access, forward TCP+UDP port 42116 on your router.%s\n' "$C_DIM" "$C_OFF"

#!/usr/bin/env bash
# ============================================================================
#  Torlamp — guided installer (Linux / NAS / Raspberry Pi)
#
#  Fresh install: choose IP-hiding (WARP), generate .env, bring up the stack,
#  auto-read the Jackett API key, enable CORS + link FlareSolverr, tune
#  TorrServer, then open the Jackett web UI so you can add search indexers
#  there (public ones instantly; login/captcha trackers via their own form).
#
#  If a server is already installed here it offers REPAIR / DELETE / QUIT.
#
#  Usage:  bash install.sh        (run from the media-server/ folder)
#  Safe to re-run — it's idempotent. UI language: English / Українська / Русский.
#
#  Non-interactive (CI / automation): NONINTERACTIVE=1, optionally ACTION=
#  install|repair|delete (delete needs FORCE=1) and WANT_WARP=0|1.
# ============================================================================
set -Eeuo pipefail
trap 'printf "\e[31mInstaller aborted (line %s).\e[0m\n" "$LINENO" >&2' ERR
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
cd "$SCRIPT_DIR" || exit 1

HELPER=(python3 lib/setup_helpers.py)
COMPOSE_FILE="docker-compose.yml"

C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'; C_RED=$'\e[31m'; C_CYAN=$'\e[36m'; C_DIM=$'\e[90m'; C_OFF=$'\e[0m'
say()  { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '  %s+ %s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_OFF"; }
die()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- Localization -----------------------------------------------------------
# shellcheck disable=SC2034  # T_* tables are read via the `t()` nameref (T_$L)
declare -A T_en=(
  [installed_title]="A media server is already installed here" [d_repair]="Re-apply config and restart the stack"
  [d_delete]="Stop and remove containers + data" [d_quit]="Exit without changes"
  [ask_action]="[R]epair, [D]elete, or [Q]uit? " [repairing]="Repairing existing installation..."
  [del_confirm]="This removes containers, volumes AND data (jackett_config, torrserver_data, warp, .env). Type 'delete' to confirm: "
  [del_cancel]="Cancelled - nothing removed." [removing]="Removing the media server..."
  [removed]="Removed containers, volumes and data. Re-run install.sh to set up again."
  [cl_title]="Space = toggle, Enter = confirm.\nCore (TorrServer + Jackett) is always installed."
  [warp_item]="Hide IP for P2P (Cloudflare WARP)" [ask_warp]="Hide your IP for P2P via Cloudflare WARP? [y/N] "
  [solverr_item]="FlareSolverr (Cloudflare bypass; ~0.5 GB RAM)"
  [ask_solverr]="Enable FlareSolverr (Cloudflare bypass for protected trackers; ~0.5 GB RAM)? [Y/n] "
  [warp_gen]="Generating a free Cloudflare WARP profile..." [warp_ok]="WARP profile generated."
  [warp_parsefail]="Could not parse WARP profile - set WARP_PRIVATE_KEY in .env manually."
  [warp_genfail]="WARP profile generation failed - you can set WARP keys in .env later."
  [writing]="Writing .env..." [env_ready]=".env ready" [starting]="Starting containers (%s)..."
  [waiting]="Waiting for Jackett..." [conf_jackett]="Configuring Jackett..."
  [api_ok]="API key read automatically; CORS + FlareSolverr linked."
  [api_fail]="Could not read Jackett API key yet - open http://localhost:9117 and re-run."
  [tuning]="Tuning TorrServer..." [torr_unreach]="TorrServer not reachable yet - re-run later to tune."
  [opening_jackett]="Opening Jackett in browser to add indexers..."
  [finished]="Done." [repaired]="Repaired." [point]="Point Lampa at your server:"
  [apilabel]="API key" [paste]="(paste it into Lampa -> Parser/Jackett)"
  [ipon]="IP hiding : ON - verify with: docker exec warp wget -qO- https://api.ipify.org"
  [reminder]="Reminder: for WAN access, forward TCP+UDP port 42116 on your router."
  [lang_prompt]="Language: [1] English  [2] Українська  [3] Русский"
  [tagline]="Fuel for your Lampa — a light local media server" [ip_select]="Select IP address for Lampa:"
  [saved_info]="Access details saved to: lampa_settings.txt"
)
# shellcheck disable=SC2034
declare -A T_uk=(
  [installed_title]="Медіасервер уже встановлено в цій папці" [d_repair]="Перевстановити конфіг і перезапустити стек"
  [d_delete]="Зупинити й видалити контейнери + дані" [d_quit]="Вийти без змін"
  [ask_action]="[R] Ремонт, [D] Видалити, [Q] Вихід? " [repairing]="Ремонт наявної інсталяції..."
  [del_confirm]="Це видалить контейнери, томи ТА дані (jackett_config, torrserver_data, warp, .env). Введіть 'delete' для підтвердження: "
  [del_cancel]="Скасовано - нічого не видалено." [removing]="Видалення медіасервера..."
  [removed]="Видалено контейнери, томи й дані. Запустіть install.sh знову, щоб налаштувати."
  [cl_title]="Пробіл = перемкнути, Enter = підтвердити.\nЯдро (TorrServer + Jackett) ставиться завжди."
  [warp_item]="Приховати IP для P2P (Cloudflare WARP)" [ask_warp]="Приховати вашу IP для P2P через Cloudflare WARP? [y/N] "
  [solverr_item]="FlareSolverr (обхід Cloudflare; ~0.5 ГБ RAM)"
  [ask_solverr]="Увімкнути FlareSolverr (обхід Cloudflare для захищених трекерів; ~0.5 ГБ RAM)? [Y/n] "
  [warp_gen]="Генерація безкоштовного профілю Cloudflare WARP..." [warp_ok]="Профіль WARP згенеровано."
  [warp_parsefail]="Не вдалося розібрати профіль WARP - впишіть WARP_PRIVATE_KEY у .env вручну."
  [warp_genfail]="Не вдалося згенерувати профіль WARP - ключі WARP можна вписати в .env пізніше."
  [writing]="Запис .env..." [env_ready]=".env готовий" [starting]="Запуск контейнерів (%s)..."
  [waiting]="Очікування Jackett..." [conf_jackett]="Налаштування Jackett..."
  [api_ok]="API-ключ зчитано автоматично; CORS + FlareSolverr під'єднано."
  [api_fail]="Поки не вдалося зчитати API-ключ Jackett - відкрийте http://localhost:9117 і запустіть знову."
  [tuning]="Оптимізація TorrServer..." [torr_unreach]="TorrServer поки недоступний - запустіть пізніше для налаштування."
  [opening_jackett]="Відкриваємо Jackett у браузері для додавання індексаторів..."
  [finished]="Готово." [repaired]="Відремонтовано." [point]="Вкажіть у Lampa адресу сервера:"
  [apilabel]="API-ключ" [paste]="(вставте в Lampa -> Парсер/Jackett)"
  [ipon]="Приховування IP: УВІМК - перевірка: docker exec warp wget -qO- https://api.ipify.org"
  [reminder]="Нагадування: для доступу з інтернету пробросьте TCP+UDP порт 42116 на роутері."
  [lang_prompt]="Мова: [1] English  [2] Українська  [3] Русский"
  [tagline]="Живлення для вашої Lampa — легкий локальний медіасервер" [ip_select]="Виберіть IP-адресу для Lampa:"
  [saved_info]="Адреси, ключі та інструкцію збережено у файл: lampa_settings.txt"
)
# shellcheck disable=SC2034
declare -A T_ru=(
  [installed_title]="Медиасервер уже установлен в этой папке" [d_repair]="Переустановить конфиг и перезапустить стек"
  [d_delete]="Остановить и удалить контейнеры + данные" [d_quit]="Выйти без изменений"
  [ask_action]="[R] Ремонт, [D] Удалить, [Q] Выход? " [repairing]="Ремонт существующей установки..."
  [del_confirm]="Это удалит контейнеры, тома И данные (jackett_config, torrserver_data, warp, .env). Введите 'delete' для подтверждения: "
  [del_cancel]="Отменено - ничего не удалено." [removing]="Удаление медиасервера..."
  [removed]="Удалены контейнеры, тома и данные. Запустите install.sh снова для установки."
  [cl_title]="Пробел = переключить, Enter = подтвердить.\nЯдро (TorrServer + Jackett) ставится всегда."
  [warp_item]="Скрыть IP для P2P (Cloudflare WARP)" [ask_warp]="Скрыть ваш IP для P2P через Cloudflare WARP? [y/N] "
  [solverr_item]="FlareSolverr (обход Cloudflare; ~0.5 ГБ RAM)"
  [ask_solverr]="Включить FlareSolverr (обход Cloudflare для защищённых трекеров; ~0.5 ГБ RAM)? [Y/n] "
  [warp_gen]="Генерация бесплатного профиля Cloudflare WARP..." [warp_ok]="Профиль WARP сгенерирован."
  [warp_parsefail]="Не удалось разобрать профиль WARP - впишите WARP_PRIVATE_KEY в .env вручную."
  [warp_genfail]="Не удалось сгенерировать профиль WARP - ключи WARP можно вписать в .env позже."
  [writing]="Запись .env..." [env_ready]=".env готов" [starting]="Запуск контейнеров (%s)..."
  [waiting]="Ожидание Jackett..." [conf_jackett]="Настройка Jackett..."
  [api_ok]="API-ключ считан автоматически; CORS + FlareSolverr подключены."
  [api_fail]="Пока не удалось считать API-ключ Jackett - откройте http://localhost:9117 и запустите снова."
  [tuning]="Оптимизация TorrServer..." [torr_unreach]="TorrServer пока недоступен - запустите позже для настройки."
  [opening_jackett]="Открываем Jackett в браузере для добавления индексаторов..."
  [finished]="Готово." [repaired]="Отремонтировано." [point]="Укажите в Lampa адрес сервера:"
  [apilabel]="API-ключ" [paste]="(вставьте в Lampa -> Парсер/Jackett)"
  [ipon]="Скрытие IP: ВКЛ - проверка: docker exec warp wget -qO- https://api.ipify.org"
  [reminder]="Напоминание: для доступа из интернета пробросьте TCP+UDP порт 42116 на роутере."
  [lang_prompt]="Язык: [1] English  [2] Українська  [3] Русский"
  [tagline]="Топливо для вашей Lampa — лёгкий локальный медиасервер" [ip_select]="Выберите IP-адрес для Lampa:"
  [saved_info]="Адреса, ключи и инструкция сохранены в файл: lampa_settings.txt"
)
t() { local k="$1"; local -n tbl="T_$L"; printf '%s' "${tbl[$k]:-${T_en[$k]}}"; }

# --- Preflight --------------------------------------------------------------
have docker  || die "Docker not found. Install Docker first: https://docs.docker.com/engine/install/"
have curl    || die "curl not found - install it (e.g. apt install curl)."
have python3 || die "python3 not found - install it (e.g. apt install python3)."
if docker compose version >/dev/null 2>&1; then DC=(docker compose)
elif have docker-compose; then DC=(docker-compose)
else die "Docker Compose not found: https://docs.docker.com/compose/install/"; fi
docker info >/dev/null 2>&1 || die "Docker is installed but the daemon isn't running. Start Docker and retry."

NONINTERACTIVE="${NONINTERACTIVE:-0}"
USE_WHIPTAIL=0
if [ "$NONINTERACTIVE" != "1" ] && have whiptail; then USE_WHIPTAIL=1; fi

# --- Language ---------------------------------------------------------------
case "${LANG_CHOICE:-${LANG:-}}" in uk*|*UA*) L=uk;; ru*|*RU*) L=ru;; *) L=en;; esac
if [ "$NONINTERACTIVE" != "1" ]; then
  if [ "$USE_WHIPTAIL" = 1 ]; then
    L=$(whiptail --title "Torlamp" --menu "Language / Мова / Язык" 12 50 3 \
      en "English" uk "Українська" ru "Русский" 3>&1 1>&2 2>&3) || L=en
  else
    printf '%s (default %s): ' "$(t lang_prompt)" "$L"; read -r a
    case "$a" in 1) L=en;; 2) L=uk;; 3) L=ru;; esac
  fi
fi

# --- Banner -----------------------------------------------------------------
if [ "$NONINTERACTIVE" != "1" ]; then
  printf '\n%s  ┌─┐ T O R L A M P%s\n' "$C_CYAN" "$C_OFF"
  printf '%s  │▓│%s %s%s%s\n\n' "$C_CYAN" "$C_OFF" "$C_DIM" "$(t tagline)" "$C_OFF"
fi

WANT_WARP="${WANT_WARP:-0}"
# FlareSolverr choice: empty = not decided yet (prompt / .env / default 1).
WANT_SOLVERR="${WANT_SOLVERR:-}"

get_env() { [ -f .env ] && grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true; }

# Generate a free Cloudflare WARP profile with wgcf (pinned version, per-arch
# SHA256-verified download). Sets WARP_KEY / WARP_ADDR.
# Returns: 0 = ok, 1 = download/registration failed, 2 = could not parse.
gen_warp_profile() {
  local script profile
  # Runs inside an alpine container native to the host arch, so `uname -m`
  # picks the right wgcf binary (amd64 PC, arm64/armv7 Raspberry Pi & NAS).
  script='set -e
apk add --no-cache curl >/dev/null 2>&1
case "$(uname -m)" in
  x86_64)        a=amd64; h=268d187e649870b603ad2e5c1b74a696251f6c2f6f075c726a174a0039b0b1e2;;
  aarch64|arm64) a=arm64; h=e5ff08d3aae5374935211053b2d64d96daaa3f1aec8e9a1dab7418125585a011;;
  armv7l|armhf)  a=armv7; h=bd40e55dae299acfa20446973ff4fc5a9a116ecaa41431aeff5f86034391f900;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1;;
esac
curl -sL -o /wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_${a}"
echo "$h  /wgcf" | sha256sum -c - >/dev/null
chmod +x /wgcf
cd /tmp
/wgcf register --accept-tos >/dev/null 2>&1
/wgcf generate >/dev/null 2>&1
cat wgcf-profile.conf'
  profile=$(docker run --rm alpine sh -c "$script" 2>/dev/null) || return 1
  WARP_KEY=$(printf '%s\n' "$profile" | awk -F' *= *' '/PrivateKey/{print $2; exit}')
  # Address holds "IPv4/32,IPv6/128" — keep only the IPv4 part.
  WARP_ADDR=$(printf '%s\n' "$profile" | awk -F' *= *' '/Address/{split($2,a,","); print a[1]; exit}')
  [ -n "$WARP_KEY" ] || return 2
}

is_installed() {
  [ -f .env ] && return 0
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^(torrserver|jackett|flaresolverr|warp)$' && return 0
  return 1
}

do_delete() {
  if [ "$NONINTERACTIVE" = "1" ]; then
    [ "${FORCE:-0}" = "1" ] || die "Refusing to DELETE without FORCE=1 in non-interactive mode."
  else
    read -r -p "$(t del_confirm)" ans
    [ "$ans" = "delete" ] || { say "$(t del_cancel)"; exit 0; }
  fi
  say "$(t removing)"
  for f in docker-compose.warp.yml docker-compose.yml; do
    "${DC[@]}" --profile flaresolverr -f "$f" down -v --remove-orphans >/dev/null 2>&1 || true
  done
  rm -rf jackett_config torrserver_data warp .env lampa_settings.txt ../lampa_settings.txt
  ok "$(t removed)"
}

# --- Existing installation? offer REPAIR / DELETE / QUIT --------------------
MODE=install
if is_installed; then
  act="${ACTION:-}"
  if [ -z "$act" ]; then
    if [ "$NONINTERACTIVE" = "1" ]; then act=repair
    elif [ "$USE_WHIPTAIL" = "1" ]; then
      act=$(whiptail --title "Torlamp" --menu "$(t installed_title)" 14 64 3 \
        REPAIR "$(t d_repair)" DELETE "$(t d_delete)" QUIT "$(t d_quit)" 3>&1 1>&2 2>&3) || act=QUIT
    else
      say "$(t installed_title)"; read -r -p "$(t ask_action)" a
      case "${a,,}" in r*) act=REPAIR;; d*) act=DELETE;; *) act=QUIT;; esac
    fi
  fi
  case "${act,,}" in
    quit)   exit 0 ;;
    delete) do_delete; exit 0 ;;
    repair) MODE=repair; say "$(t repairing)"
            WARP_KEY_SET=0
            if [ -n "$(get_env WARP_PRIVATE_KEY)" ]; then WANT_WARP=1; WARP_KEY_SET=1
            elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx warp; then WANT_WARP=1; fi
            # Keep the recorded FlareSolverr choice; old installs (no key
            # in .env) always had it, so default to on.
            if [ -z "$WANT_SOLVERR" ]; then
              WANT_SOLVERR=$(get_env ENABLE_FLARESOLVERR)
            fi
            [ -f .env ] || cp .env.example .env ;;
    *)      MODE=repair ;;
  esac
  # If we want WARP but the key is missing — generate it now (same as fresh install)
  if [ "$WANT_WARP" -eq 1 ] && [ "${WARP_KEY_SET:-0}" -eq 0 ]; then
    say "$(t warp_gen)"
    if gen_warp_profile; then
      "${HELPER[@]}" render-env .env .env \
        --set "WARP_PRIVATE_KEY=${WARP_KEY}" --set "WARP_ADDRESS_V4=${WARP_ADDR:-172.16.0.2/32}"
      ok "$(t warp_ok)"
    else
      case $? in
        2) warn "$(t warp_parsefail)" ;;
        *) warn "$(t warp_genfail)" ;;
      esac
    fi
  fi
fi

# --- Fresh install: choose IP hiding ----------------------------------------
if [ "$MODE" = install ]; then
  if [ "$NONINTERACTIVE" = "1" ]; then
    :
  elif [ "$USE_WHIPTAIL" -eq 1 ]; then
    chosen=$(whiptail --title "Torlamp" --checklist "$(t cl_title)" 14 70 2 \
      solverr "$(t solverr_item)" ON \
      warp "$(t warp_item)" OFF 3>&1 1>&2 2>&3) || die "Cancelled."
    WANT_SOLVERR=0
    [[ "$chosen" == *solverr* ]] && WANT_SOLVERR=1
    [[ "$chosen" == *warp* ]] && WANT_WARP=1
  else
    read -r -p "$(t ask_solverr)" a
    case "${a,,}" in n*|н*) WANT_SOLVERR=0;; *) WANT_SOLVERR=1;; esac
    read -r -p "$(t ask_warp)" a; [[ "${a,,}" == y* ]] && WANT_WARP=1
  fi

  # WARP profile
  WARP_KEY="${WARP_PRIVATE_KEY:-}"; WARP_ADDR="${WARP_ADDRESS_V4:-172.16.0.2/32}"
  if [ "$WANT_WARP" -eq 1 ] && [ -z "$WARP_KEY" ]; then
    say "$(t warp_gen)"
    if gen_warp_profile; then
      ok "$(t warp_ok)"
    else
      case $? in
        2) warn "$(t warp_parsefail)" ;;
        *) warn "$(t warp_genfail)" ;;
      esac
    fi
  fi

  say "$(t writing)"
  env_src=".env"; [ -f .env ] || env_src=".env.example"
  "${HELPER[@]}" render-env "$env_src" .env \
    --set "WARP_PRIVATE_KEY=${WARP_KEY}" --set "WARP_ADDRESS_V4=${WARP_ADDR:-172.16.0.2/32}"
  ok "$(t env_ready)"
fi

# Persist the FlareSolverr choice (default: on) so repair re-runs keep it,
# and keep secrets in .env readable by the owner only.
[ -n "$WANT_SOLVERR" ] || WANT_SOLVERR=1
[ -f .env ] || cp .env.example .env
"${HELPER[@]}" render-env .env .env --set "ENABLE_FLARESOLVERR=${WANT_SOLVERR}"
chmod 600 .env 2>/dev/null || true

# --- Bring up the stack -----------------------------------------------------
[ "$WANT_WARP" -eq 1 ] && COMPOSE_FILE="docker-compose.warp.yml"
PROFILE_ARGS=()
if [ "$WANT_SOLVERR" = "1" ]; then
  PROFILE_ARGS=(--profile flaresolverr)
else
  # Choice switched to off — drop a container left from an earlier install.
  docker rm -f flaresolverr >/dev/null 2>&1 || true
fi
# linuxserver/jackett writes its config as PUID:PGID. Match the current user so
# this script can rewrite ServerConfig.json afterward (enable CORS, read key).
export PUID="${PUID:-$(id -u)}" PGID="${PGID:-$(id -g)}"
start_msg="$(t starting)"; say "${start_msg/\%s/$COMPOSE_FILE}"
"${DC[@]}" ${PROFILE_ARGS[@]+"${PROFILE_ARGS[@]}"} -f "$COMPOSE_FILE" up -d

# --- Wait for Jackett, read API key, enable CORS, link FlareSolverr ---------
say "$(t waiting)"
for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:9117" && break; sleep 2; done
CFG="jackett_config/Jackett/ServerConfig.json"
for _ in $(seq 1 15); do [ -f "$CFG" ] && break; sleep 2; done

say "$(t conf_jackett)"
FS_URL=$(get_env JACKETT_FLARESOLVERR_URL)
FS_URL="${FS_URL:-http://flaresolverr:8191}"
# FlareSolverr disabled -> clear the link so Jackett doesn't wait on it.
[ "$WANT_SOLVERR" = "1" ] || FS_URL=""
APIKEY=$("${HELPER[@]}" patch-jackett "$CFG" "$FS_URL") || APIKEY=""
if [ -n "$APIKEY" ]; then
  ok "$(t api_ok)"
  "${HELPER[@]}" render-env .env .env --set "JACKETT_APIKEY=$APIKEY"
  "${DC[@]}" -f "$COMPOSE_FILE" restart jackett >/dev/null 2>&1 || true
  # Jackett needs a few seconds to serve again after a restart — wait so we
  # don't hand back control (or add indexers) while it's still coming up.
  for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:9117" && break; sleep 2; done
else
  warn "$(t api_fail)"
fi

# --- Tune TorrServer --------------------------------------------------------
say "$(t tuning)"
TUNE_ARGS=()
CACHE_ENV=$(get_env TORRSERVER_CACHE_SIZE)
if [ -n "$CACHE_ENV" ]; then
  TUNE_ARGS+=(--cache-size "$CACHE_ENV")           # explicit .env value wins
else
  # Auto cache: helper picks RAM/4 clamped to 256 MiB..2 GiB (RPi-safe).
  TOTAL_RAM=$(awk '/MemTotal/{print $2*1024; exit}' /proc/meminfo 2>/dev/null || true)
  [ -n "${TOTAL_RAM:-}" ] || TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null || true)
  [ -n "${TOTAL_RAM:-}" ] && TUNE_ARGS+=(--total-ram "$TOTAL_RAM")
fi
"${HELPER[@]}" tune-torrserver "http://127.0.0.1:8090" \
  ${TUNE_ARGS[@]+"${TUNE_ARGS[@]}"} || warn "$(t torr_unreach)"

# --- Open Jackett to add search indexers ------------------------------------
if [ "$NONINTERACTIVE" != "1" ] && [ -n "$APIKEY" ]; then
  say "$(t opening_jackett)"
  if have xdg-open; then xdg-open "http://localhost:9117" >/dev/null 2>&1 || true
  elif have open; then open "http://localhost:9117" >/dev/null 2>&1 || true
  fi
fi

# --- Summary ----------------------------------------------------------------
LAN_IPS=()
if have ip; then
  while read -r line; do
    ip_addr=$(echo "$line" | awk '{print $4}' | cut -d/ -f1)
    if [ -n "$ip_addr" ] && [ "$ip_addr" != "127.0.0.1" ]; then
      LAN_IPS+=("$ip_addr")
    fi
  done < <(ip -4 -o addr show scope global 2>/dev/null)
fi
if [ "${#LAN_IPS[@]}" -eq 0 ] && have hostname; then
  for ip_addr in $(hostname -I 2>/dev/null); do
    [ "$ip_addr" != "127.0.0.1" ] && LAN_IPS+=("$ip_addr")
  done
fi

if [ "${#LAN_IPS[@]}" -gt 1 ] && [ "$NONINTERACTIVE" != "1" ]; then
  echo
  say "$(t ip_select)"
  select picked_ip in "${LAN_IPS[@]}"; do
    if [ -n "$picked_ip" ]; then
      LAN_IP="$picked_ip"
      break
    fi
  done
elif [ "${#LAN_IPS[@]}" -ge 1 ]; then
  LAN_IP="${LAN_IPS[0]}"
else
  LAN_IP="<PC-IP>"
fi

echo
say "$([ "$MODE" = repair ] && t repaired || t finished) $(t point)"
printf '  %sTorrServer:%s http://%s:8090\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
printf '  %sJackett   :%s http://%s:9117\n' "$C_GREEN" "$C_OFF" "$LAN_IP"
[ -n "${APIKEY:-}" ] && printf '  %s%s   :%s %s\n%s  %s%s\n' \
  "$C_GREEN" "$(t apilabel)" "$C_OFF" "$APIKEY" "$C_DIM" "$(t paste)" "$C_OFF"
[ "$WANT_WARP" -eq 1 ] && printf '  %s%s%s\n' "$C_GREEN" "$(t ipon)" "$C_OFF"
printf '%s  %s%s\n' "$C_DIM" "$(t reminder)" "$C_OFF"

cat <<EOF > "$SCRIPT_DIR/lampa_settings.txt"
==================================================
  TORLAMP — MEDIA SERVER ACCESS INFO
==================================================
Date / Дата : $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

TorrServer URL : http://${LAN_IP}:8090
Jackett URL    : http://${LAN_IP}:9117
Jackett API Key: ${APIKEY:-}

Lampa Setup / Налаштування в Lampa:
1. Lampa -> Настройки -> Парсер (або Jackett) -> Увімкнути
2. Адрес парсера / Jackett : http://${LAN_IP}:9117
3. API ключ                : ${APIKEY:-}
4. Lampa -> Настройки -> Торренты -> TorrServer
5. Адрес TorrServer        : http://${LAN_IP}:8090
==================================================
EOF
cp "$SCRIPT_DIR/lampa_settings.txt" "$SCRIPT_DIR/../lampa_settings.txt" 2>/dev/null || true
# The file holds the API key — owner-only, like .env.
chmod 600 "$SCRIPT_DIR/lampa_settings.txt" "$SCRIPT_DIR/../lampa_settings.txt" 2>/dev/null || true
printf '%s  %s%s\n' "$C_DIM" "$(t saved_info)" "$C_OFF"

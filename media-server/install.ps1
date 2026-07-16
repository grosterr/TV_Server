<#
.SYNOPSIS
    Torlamp — guided installer (Windows).

.DESCRIPTION
    Choose IP-hiding (WARP), then this script generates .env, brings up the
    Docker stack, runs configure.ps1 (auto API key, CORS, FlareSolverr, tuning)
    and opens the Jackett web UI so you can add search indexers there.

    If a server is already installed here, it instead offers REPAIR / DELETE /
    QUIT — plus UPDATE when a newer GitHub release than the local VERSION
    exists (downloads the release, replaces the stack files, keeps all data,
    then relaunches itself as repair with a docker image pull).
    UI language: English / Українська / Русский.
    TORLAMP_SKIP_UPDATE_CHECK=1 disables the release check.

    Double-click install.bat, or run:  ./install.ps1
    Safe to re-run — it's idempotent.
#>
[CmdletBinding()]
param(
    # Skip the action menu: 'repair' | 'update' | 'delete'. Used by the
    # self-update restart; mirrors install.sh's ACTION env variable.
    [string]$Action = '',
    # Preselect UI language ('en'|'uk'|'ru') — skips the language menu.
    [string]$Lang = ''
)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# --- Version / updates -------------------------------------------------------
$TorlampRepo = 'grosterr/torlamp'
$rootDir = Split-Path $PSScriptRoot -Parent
# VERSION ships at the bundle root; old (pre-1.1) installs have none -> '0',
# which makes any published release count as an update.
$localVersion = '0'
foreach ($vf in (Join-Path $rootDir 'VERSION'), (Join-Path $PSScriptRoot 'VERSION')) {
    if (Test-Path $vf) { $localVersion = (Get-Content -Raw $vf).Trim(); break }
}

function ConvertTo-VersionTuple([string]$s) {
    # 'v1' -> 1,0,0; '1.1' -> 1,1,0; 'v1.2.3-beta4' -> 1,2,3; junk -> 0,0,0
    $nums = @([regex]::Matches($s, '\d+') | ForEach-Object { [int]$_.Value } | Select-Object -First 3)
    while ($nums.Count -lt 3) { $nums += 0 }
    return ,$nums
}

function Test-NewerVersion([string]$Remote, [string]$Local) {
    $r = ConvertTo-VersionTuple $Remote
    $l = ConvertTo-VersionTuple $Local
    for ($i = 0; $i -lt 3; $i++) {
        if ($r[$i] -ne $l[$i]) { return ($r[$i] -gt $l[$i]) }
    }
    return $false
}

function Get-LatestReleaseTag {
    # Best-effort: returns the newer release tag or '' (up-to-date/offline).
    if ($env:TORLAMP_SKIP_UPDATE_CHECK -eq '1') { return '' }
    try {
        $rel = Invoke-RestMethod "https://api.github.com/repos/$TorlampRepo/releases/latest" `
            -TimeoutSec 6 -Headers @{ 'User-Agent' = 'torlamp-installer' }
        $tag = [string]$rel.tag_name
    } catch { return '' }
    if ($tag -and (Test-NewerVersion $tag $localVersion)) { return $tag }
    return ''
}

function Test-Cmd { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Set-EnvValue { param([string]$Path,[string]$Key,[string]$Value)
    $lines = if (Test-Path $Path) { Get-Content -LiteralPath $Path } else { @() }
    if ($lines -match "(?m)^$([regex]::Escape($Key))=") {
        $lines = $lines -replace "(?m)^$([regex]::Escape($Key))=.*$", "$Key=$Value"
    } else { $lines += "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Get-EnvValue { param([string]$Path,[string]$Key)
    if (-not (Test-Path $Path)) { return '' }
    $line = Get-Content -LiteralPath $Path |
        Where-Object { $_ -match "^$([regex]::Escape($Key))=" } | Select-Object -Last 1
    if ($line) { ($line -split '=', 2)[1].Trim() } else { '' }
}

function New-WarpProfile {
    <#
      Generates a free Cloudflare WARP profile with wgcf (pinned version,
      per-arch SHA256-verified download; arch is detected INSIDE the container,
      so arm64/armv7 hosts like a Raspberry Pi get the right binary).
      Returns @{ Status='ok'; Key=..; Addr=.. } | @{ Status='parsefail' } |
      @{ Status='genfail' }.
    #>
    $gen = @'
set -e
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
cat wgcf-profile.conf
'@
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $warpProfile = docker run --rm alpine sh -c $gen 2>$null
    $ErrorActionPreference = $oldEap
    if (-not $warpProfile) { return @{ Status = 'genfail' } }
    $keyLine  = $warpProfile | Select-String 'PrivateKey' | Select-Object -First 1
    $addrLine = $warpProfile | Select-String 'Address'    | Select-Object -First 1
    if (-not $keyLine) { return @{ Status = 'parsefail' } }
    $key = $keyLine.Line.Split('=',2)[1].Trim()
    if (-not $key) { return @{ Status = 'parsefail' } }
    # Address holds "IPv4/32,IPv6/128" — keep only the IPv4 part.
    $addr = if ($addrLine) { $addrLine.Line.Split('=',2)[1].Split(',')[0].Trim() }
            else           { '172.16.0.2/32' }
    return @{ Status = 'ok'; Key = $key; Addr = $addr }
}

function Update-Install {
    <#
      Download release $Tag and replace the stack files with it. Data (.env,
      jackett_config/, torrserver_data/, warp/) is NOT in the release archive,
      so copying over never touches it. Returns $true on success — the caller
      then relaunches the freshly downloaded installer as repair + image pull.
    #>
    param([string]$Tag)
    if ((Test-Path (Join-Path $rootDir '.git')) -or (Test-Path (Join-Path $PSScriptRoot '.git'))) {
        Write-Warning (L 'upd_git'); return $false
    }
    if (-not $Tag) { Write-Warning (L 'upd_fail'); return $false }
    Write-Host ((L 'upd_downloading') -f $Tag) -ForegroundColor Cyan
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('torlamp-update-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $zip = Join-Path $tmp 'release.zip'
        Invoke-WebRequest "https://github.com/$TorlampRepo/archive/refs/tags/$Tag.zip" `
            -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp
        $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'media-server'))) {
            Write-Warning (L 'upd_fail'); return $false
        }
        if ((Test-Path (Join-Path $rootDir 'install.bat')) -or (Test-Path (Join-Path $rootDir 'VERSION'))) {
            Copy-Item -Path (Join-Path $src.FullName '*') -Destination $rootDir -Recurse -Force
            $dest = $rootDir
        } else {
            # media-server/ was copied around standalone — update just this folder.
            Copy-Item -Path (Join-Path $src.FullName 'media-server\*') -Destination $PSScriptRoot -Recurse -Force
            Copy-Item -Path (Join-Path $src.FullName 'VERSION') -Destination $PSScriptRoot -Force -ErrorAction SilentlyContinue
            $dest = $PSScriptRoot
        }
        # Releases older than the update system ship no VERSION file — stamp
        # the tag we just installed so the check doesn't re-offer it forever.
        $vFile = Join-Path $dest 'VERSION'
        if (-not (Test-Path $vFile)) {
            Set-Content -LiteralPath $vFile -Value ($Tag -replace '^v', '') -Encoding UTF8
        }
    } catch {
        Write-Warning (L 'upd_fail'); return $false
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    # Keep the TorrServer image pin in .env in sync with the shipped default —
    # it's our crash-bug pin, not a user preference.
    $pin = Get-EnvValue (Join-Path $PSScriptRoot '.env.example') 'TORRSERVER_VERSION'
    if ($pin -and (Test-Path .env)) { Set-EnvValue .env 'TORRSERVER_VERSION' $pin }
    Write-Host ('  + ' + ((L 'upd_done') -f $Tag)) -ForegroundColor Green
    return $true
}

# --- Single-select menu (arrows to move, Enter to pick) ----------------------
function Show-Menu {
    param([string]$Title, [object[]]$Options)   # each: @{ Key=..; Desc=.. }
    $idx = 0
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Clear-Host
            Write-Host $Title -ForegroundColor Cyan
            Write-Host "(up/down move - Enter select)`n" -ForegroundColor DarkGray
            for ($i = 0; $i -lt $Options.Count; $i++) {
                $line = "  {0,-16}{1}" -f $Options[$i].Key, $Options[$i].Desc
                if ($i -eq $idx) { Write-Host (">$line") -ForegroundColor Black -BackgroundColor Gray }
                else             { Write-Host (" $line") }
            }
            switch ([Console]::ReadKey($true).Key) {
                'UpArrow'   { $idx = ($idx - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $idx = ($idx + 1) % $Options.Count }
                'Enter'     { return $Options[$idx].Key }
                'Escape'    { return 'QUIT' }
            }
        }
    } finally { [Console]::CursorVisible = $true }
}

function Test-Installed {
    if (Test-Path .env) { return $true }
    $names = docker ps -a --format '{{.Names}}' 2>$null
    return [bool]($names | Where-Object { $_ -in 'torrserver','jackett','flaresolverr','warp' })
}

function Remove-Install { param([string[]]$DC)
    $confirm = Read-Host (L 'del_confirm')
    if ($confirm -ne 'delete') { Write-Host (L 'del_cancel') -ForegroundColor Cyan; return }
    Write-Host (L 'removing') -ForegroundColor Cyan
    foreach ($f in 'docker-compose.warp.yml','docker-compose.yml') {
        & $DC[0] @($DC[1..($DC.Count-1)]) --profile flaresolverr -f $f down -v --remove-orphans *> $null
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue jackett_config, torrserver_data, warp, .env, lampa_settings.txt, ..\lampa_settings.txt
    Write-Host ("  + " + (L 'removed')) -ForegroundColor Green
}

# --- Localization -----------------------------------------------------------
$MSG = @{
  en = @{
    lang_title='Language / Мова / Язык'; installed_title='A media server is already installed here'
    d_repair='Re-apply config and restart the stack'; d_delete='Stop and remove containers + data'; d_quit='Exit without changes'
    nothing='Nothing to do.'; del_confirm="Removes containers, volumes AND data (jackett_config, torrserver_data, warp, .env). Type 'delete' to confirm"
    del_cancel='Cancelled - nothing removed.'; removing='Removing the media server...'
    removed='Removed containers, volumes and data. Re-run install to set up again.'
    d_update='Download the new version and update'; upd_check='Checking for updates...'
    upd_avail='Update available: {0} (installed: {1})'
    upd_git="This folder is a git checkout - update with 'git pull' instead. Refreshing Docker images only."
    upd_fail='Could not download the update - check your internet connection and try again later.'
    upd_downloading='Downloading Torlamp {0}...'; upd_done='Files updated to {0} - restarting the installer...'
    pulling='Pulling fresh Docker images...'
    repairing='Repairing existing installation...'; cl_title='Torlamp — core (TorrServer + Jackett) is always installed'
    solverr_item='FlareSolverr (Cloudflare bypass for protected trackers; ~0.5 GB RAM)'
    warp_item='Hide IP for P2P (Cloudflare WARP)'; warp_gen='Generating a free Cloudflare WARP profile...'
    warp_ok='WARP profile generated.'; warp_parsefail='Could not parse WARP profile - set WARP_PRIVATE_KEY in .env manually.'
    warp_genfail='WARP profile generation failed - set WARP keys in .env later.'; starting='Starting containers ({0})...'
    configuring='Configuring services...'; opening_jackett='Opening Jackett in browser to add indexers...'
    done='Done.'; repaired='Repaired.'; point='Point Lampa at your server:'; apilabel='API key'
    paste='(paste it into Lampa -> Parser/Jackett)'; ipon='IP hiding : ON'; reminder='Reminder: for WAN access, forward TCP+UDP port 42116 on your router.'
    tagline='Fuel for your Lampa - a light local media server'; ip_select='Select network adapter / IP for Lampa'
    saved_info='Access details saved to: lampa_settings.txt'
  }
  uk = @{
    lang_title='Language / Мова / Язык'; installed_title='Медіасервер уже встановлено в цій папці'
    d_repair='Перевстановити конфіг і перезапустити стек'; d_delete='Зупинити й видалити контейнери + дані'; d_quit='Вийти без змін'
    nothing='Немає що робити.'; del_confirm="Видаляє контейнери, томи ТА дані (jackett_config, torrserver_data, warp, .env). Введіть 'delete' для підтвердження"
    del_cancel='Скасовано - нічого не видалено.'; removing='Видалення медіасервера...'
    removed='Видалено контейнери, томи й дані. Запустіть install знову для налаштування.'
    d_update='Завантажити нову версію та оновити'; upd_check='Перевірка оновлень...'
    upd_avail='Доступне оновлення: {0} (встановлено: {1})'
    upd_git="Ця тека - git-репозиторій: оновлюйтеся через 'git pull'. Наразі лише оновлю Docker-образи."
    upd_fail='Не вдалося завантажити оновлення - перевірте інтернет і спробуйте пізніше.'
    upd_downloading='Завантаження Torlamp {0}...'; upd_done='Файли оновлено до {0} - перезапуск інсталятора...'
    pulling='Завантаження свіжих Docker-образів...'
    repairing='Ремонт наявної інсталяції...'; cl_title='Torlamp — ядро (TorrServer + Jackett) ставиться завжди'
    solverr_item='FlareSolverr (обхід Cloudflare для захищених трекерів; ~0.5 ГБ RAM)'
    warp_item='Приховати IP для P2P (Cloudflare WARP)'; warp_gen='Генерація безкоштовного профілю Cloudflare WARP...'
    warp_ok='Профіль WARP згенеровано.'; warp_parsefail='Не вдалося розібрати профіль WARP - впишіть WARP_PRIVATE_KEY у .env вручну.'
    warp_genfail='Не вдалося згенерувати профіль WARP - впишіть ключі WARP у .env пізніше.'; starting='Запуск контейнерів ({0})...'
    configuring='Налаштування сервісів...'; opening_jackett='Відкриваємо Jackett у браузері для додавання індексаторів...'
    done='Готово.'; repaired='Відремонтовано.'; point='Вкажіть у Lampa адресу сервера:'; apilabel='API-ключ'
    paste='(вставте в Lampa -> Парсер/Jackett)'; ipon='Приховування IP: УВІМК'; reminder='Нагадування: для доступу з інтернету пробросьте TCP+UDP порт 42116 на роутері.'
    tagline='Живлення для вашої Lampa - легкий локальний медіасервер'; ip_select='Виберіть мережевий адаптер / IP для Lampa'
    saved_info='Адреси, ключі та інструкцію збережено у файл: lampa_settings.txt'
  }
  ru = @{
    lang_title='Language / Мова / Язык'; installed_title='Медиасервер уже установлен в этой папке'
    d_repair='Переустановить конфиг и перезапустить стек'; d_delete='Остановить и удалить контейнеры + данные'; d_quit='Выйти без изменений'
    nothing='Нечего делать.'; del_confirm="Удаляет контейнеры, тома И данные (jackett_config, torrserver_data, warp, .env). Введите 'delete' для подтверждения"
    del_cancel='Отменено - ничего не удалено.'; removing='Удаление медиасервера...'
    removed='Удалены контейнеры, тома и данные. Запустите install снова для установки.'
    d_update='Скачать новую версию и обновить'; upd_check='Проверка обновлений...'
    upd_avail='Доступно обновление: {0} (установлено: {1})'
    upd_git="Эта папка - git-репозиторий: обновляйтесь через 'git pull'. Пока лишь обновлю Docker-образы."
    upd_fail='Не удалось скачать обновление - проверьте интернет и попробуйте позже.'
    upd_downloading='Скачивание Torlamp {0}...'; upd_done='Файлы обновлены до {0} - перезапуск инсталлятора...'
    pulling='Загрузка свежих Docker-образов...'
    repairing='Ремонт существующей установки...'; cl_title='Torlamp — ядро (TorrServer + Jackett) ставится всегда'
    solverr_item='FlareSolverr (обход Cloudflare для защищённых трекеров; ~0.5 ГБ RAM)'
    warp_item='Скрыть IP для P2P (Cloudflare WARP)'; warp_gen='Генерация бесплатного профиля Cloudflare WARP...'
    warp_ok='Профиль WARP сгенерирован.'; warp_parsefail='Не удалось разобрать профиль WARP - впишите WARP_PRIVATE_KEY в .env вручную.'
    warp_genfail='Не удалось сгенерировать профиль WARP - впишите ключи WARP в .env позже.'; starting='Запуск контейнеров ({0})...'
    configuring='Настройка сервисов...'; opening_jackett='Открываем Jackett в браузере для добавления индексаторов...'
    done='Готово.'; repaired='Отремонтировано.'; point='Укажите в Lampa адрес сервера:'; apilabel='API-ключ'
    paste='(вставьте в Lampa -> Парсер/Jackett)'; ipon='Скрытие IP: ВКЛ'; reminder='Напоминание: для доступа из интернета пробросьте TCP+UDP порт 42116 на роутере.'
    tagline='Топливо для вашей Lampa - лёгкий локальный медиасервер'; ip_select='Выберите сетевой адаптер / IP для Lampa'
    saved_info='Адреса, ключи и инструкция сохранены в файл: lampa_settings.txt'
  }
}
function L([string]$k) { $t = $MSG[$script:Lang]; if ($t.ContainsKey($k)) { $t[$k] } else { $MSG.en[$k] } }

# --- Preflight --------------------------------------------------------------
if (-not (Test-Cmd docker)) { throw "Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" }
docker compose version *> $null
if ($LASTEXITCODE -eq 0)          { $DC = @('docker','compose') }
elseif (Test-Cmd docker-compose)  { $DC = @('docker-compose') }
else { throw "Docker Compose not found." }
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker is installed but the daemon isn't running. Start Docker Desktop and retry." }

# --- Language ---------------------------------------------------------------
$script:Lang = switch ((Get-Culture).TwoLetterISOLanguageName) { 'uk' { 'uk' } 'ru' { 'ru' } default { 'en' } }
if ($Lang -in 'en','uk','ru') {
    $script:Lang = $Lang   # explicit (e.g. the post-update restart) — no menu
} else {
    $pick = Show-Menu -Title (L 'lang_title') -Options @(
        [pscustomobject]@{ Key = 'EN'; Desc = 'English' }
        [pscustomobject]@{ Key = 'UK'; Desc = 'Українська' }
        [pscustomobject]@{ Key = 'RU'; Desc = 'Русский' }
    )
    switch ($pick) { 'EN' { $script:Lang = 'en' } 'UK' { $script:Lang = 'uk' } 'RU' { $script:Lang = 'ru' } }
}

# --- Existing installation? offer UPDATE / REPAIR / DELETE / QUIT -----------
$mode = 'install'
$latestTag = ''
$script:DoPull = $env:TORLAMP_PULL -eq '1'
if (Test-Installed) {
    $act = $Action
    # Best-effort version check: before the interactive menu, or when the
    # caller explicitly asked for -Action update.
    if (-not $act -or $act -eq 'update') {
        Write-Host (L 'upd_check') -ForegroundColor DarkGray
        $latestTag = Get-LatestReleaseTag
    }
    if (-not $act) {
        $title = (L 'installed_title')
        $opts = @()
        if ($latestTag) {
            $title += "`n" + ((L 'upd_avail') -f $latestTag, $localVersion)
            $opts += [pscustomobject]@{ Key = 'UPDATE'; Desc = (L 'd_update') }
        }
        $opts += [pscustomobject]@{ Key = 'REPAIR'; Desc = (L 'd_repair') }
        $opts += [pscustomobject]@{ Key = 'DELETE'; Desc = (L 'd_delete') }
        $opts += [pscustomobject]@{ Key = 'QUIT';   Desc = (L 'd_quit') }
        $act = Show-Menu -Title $title -Options $opts
    }
    Clear-Host
    switch ($act) {
        'QUIT'   { Write-Host (L 'nothing') -ForegroundColor Cyan; return }
        'DELETE' { Remove-Install -DC $DC; return }
        'UPDATE' {
            if (Update-Install -Tag $latestTag) {
                # Hand over to the freshly downloaded installer (parsed anew
                # by the & operator): finish as repair + image pull.
                $env:TORLAMP_PULL = '1'
                & (Join-Path $PSScriptRoot 'install.ps1') -Action repair -Lang $script:Lang
                return
            }
            # Fell back (git checkout / download failed): refresh images at least.
            $script:DoPull = $true
            $mode = 'repair'
        }
        'REPAIR' { $mode = 'repair' }
    }
}

$wantWarp = $false
$wantSolverr = $true
if ($mode -eq 'install') {
    Clear-Host
    Write-Host (L 'cl_title') -ForegroundColor Cyan
    $a = Read-Host ((L 'solverr_item') + "? [Y/n]")
    $wantSolverr = -not ($a -match '^(n|н)')
    $a = Read-Host ((L 'warp_item') + "? [y/N]")
    if ($a -match '^(y|т|д)') { $wantWarp = $true }
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }

    if ($wantWarp) {
        Write-Host "`n$(L 'warp_gen')" -ForegroundColor Cyan
        $wp = New-WarpProfile
        switch ($wp.Status) {
            'ok'        { Set-EnvValue .env 'WARP_PRIVATE_KEY' $wp.Key
                          Set-EnvValue .env 'WARP_ADDRESS_V4' $wp.Addr
                          Write-Host "  + $(L 'warp_ok')" -ForegroundColor Green }
            'parsefail' { Write-Warning (L 'warp_parsefail') }
            default     { Write-Warning (L 'warp_genfail') }
        }
    }
} else {
    Write-Host (L 'repairing') -ForegroundColor Cyan
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    $warpInEnv = [bool](Get-Content .env | Where-Object { $_ -match '^WARP_PRIVATE_KEY=.+' })
    $warpRunning = (docker ps -a --format '{{.Names}}' 2>$null) -contains 'warp'
    $wantWarp = $warpInEnv -or $warpRunning
    # Keep the recorded FlareSolverr choice; old installs (no key in .env)
    # always had it, so default to on.
    $wantSolverr = (Get-EnvValue .env 'ENABLE_FLARESOLVERR') -ne '0'
    # If we want WARP but the key is missing — generate it now (same as fresh install)
    if ($wantWarp -and -not $warpInEnv) {
        Write-Host "`n$(L 'warp_gen')" -ForegroundColor Cyan
        $wp = New-WarpProfile
        switch ($wp.Status) {
            'ok'        { Set-EnvValue .env 'WARP_PRIVATE_KEY' $wp.Key
                          Set-EnvValue .env 'WARP_ADDRESS_V4' $wp.Addr
                          Write-Host "  + $(L 'warp_ok')" -ForegroundColor Green }
            'parsefail' { Write-Warning (L 'warp_parsefail') }
            default     { Write-Warning (L 'warp_genfail') }
        }
    }
}
# Persist the FlareSolverr choice so repair re-runs keep it.
Set-EnvValue .env 'ENABLE_FLARESOLVERR' $(if ($wantSolverr) { '1' } else { '0' })

# --- Banner -----------------------------------------------------------------
Write-Host "`n  T O R L A M P" -ForegroundColor Cyan
Write-Host "  $(L 'tagline')" -ForegroundColor DarkGray

# --- Bring up the stack -----------------------------------------------------
$composeFile = if ($wantWarp) { 'docker-compose.warp.yml' } else { 'docker-compose.yml' }
$profileArgs = @()
if ($wantSolverr) { $profileArgs = @('--profile','flaresolverr') }
else {
    # Choice switched to off — drop a container left from an earlier install.
    docker rm -f flaresolverr *> $null
}
# After an update: refresh images (new pinned tags + :latest ones). Soft —
# an offline pull just keeps the current images.
if ($script:DoPull) {
    Write-Host "`n$(L 'pulling')" -ForegroundColor Cyan
    & $DC[0] @($DC[1..($DC.Count-1)]) @profileArgs -f $composeFile pull
    Remove-Item Env:TORLAMP_PULL -ErrorAction SilentlyContinue
}
Write-Host ("`n" + ((L 'starting') -f $composeFile)) -ForegroundColor Cyan
& $DC[0] @($DC[1..($DC.Count-1)]) @profileArgs -f $composeFile up -d

# --- Configure (auto API key, CORS, FlareSolverr, TorrServer tuning) --------
Write-Host "`n$(L 'configuring')" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'configure.ps1')

$apiKey = try { (Get-Content -Raw 'jackett_config/Jackett/ServerConfig.json' | ConvertFrom-Json).APIKey } catch { '' }

# --- Open Jackett to add search indexers ------------------------------------
if ($apiKey) {
    Write-Host "`n$(L 'opening_jackett')" -ForegroundColor Cyan
    if ($IsWindows -or $IsWindows -eq $null) {
        Start-Process "http://localhost:9117"
    } elseif ($IsLinux -and (Test-Cmd xdg-open)) {
        & xdg-open "http://localhost:9117"
    } elseif ($IsMacOS -and (Test-Cmd open)) {
        & open "http://localhost:9117"
    }
}

# --- Summary ----------------------------------------------------------------
$candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' -and
                   $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Hyper-V' } |
    Sort-Object {
        if ($_.IPAddress -match '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[0-1]))\.') { 0 } else { 1 }
    }, { $_.InterfaceIndex })

$lan = '<PC-IP>'
if ($candidates.Count -eq 1) {
    $lan = $candidates[0].IPAddress
} elseif ($candidates.Count -gt 1) {
    $opts = @()
    foreach ($c in $candidates) {
        $opts += [pscustomobject]@{ Key = $c.IPAddress; Desc = $c.InterfaceAlias }
    }
    $picked = Show-Menu -Title (L 'ip_select') -Options $opts
    if ($picked -and $picked -ne 'QUIT') {
        $lan = $picked
    } else {
        $lan = $candidates[0].IPAddress
    }
}

$headline = if ($mode -eq 'repair') { L 'repaired' } else { L 'done' }
Write-Host "`n$headline $(L 'point')" -ForegroundColor Cyan
Write-Host "  TorrServer: http://$lan`:8090" -ForegroundColor Green
Write-Host "  Jackett   : http://$lan`:9117" -ForegroundColor Green
if ($apiKey) {
    Write-Host "  $(L 'apilabel')   : $apiKey" -ForegroundColor Green
    Write-Host "  $(L 'paste')" -ForegroundColor DarkGray
}
if ($wantWarp) {
    Write-Host "  $(L 'ipon') - docker exec warp wget -qO- https://api.ipify.org" -ForegroundColor Green
}
Write-Host "  $(L 'reminder')" -ForegroundColor DarkGray

$settingsText = @"
==================================================
  TORLAMP — MEDIA SERVER ACCESS INFO
==================================================
Date / Дата : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

TorrServer URL : http://$lan`:8090
Jackett URL    : http://$lan`:9117
Jackett API Key: $apiKey

Lampa Setup / Налаштування в Lampa:
1. Lampa -> Настройки -> Парсер (або Jackett) -> Увімкнути
2. Адрес парсера / Jackett : http://$lan`:9117
3. API ключ                : $apiKey
4. Lampa -> Настройки -> Торренты -> TorrServer
5. Адрес TorrServer        : http://$lan`:8090
==================================================
"@
try {
    $outLocal = Join-Path $PSScriptRoot 'lampa_settings.txt'
    $outRoot  = Join-Path (Split-Path $PSScriptRoot -Parent) 'lampa_settings.txt'
    [System.IO.File]::WriteAllText($outLocal, $settingsText, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($outRoot,  $settingsText, [System.Text.Encoding]::UTF8)
} catch {}
Write-Host "  $(L 'saved_info')" -ForegroundColor DarkGray

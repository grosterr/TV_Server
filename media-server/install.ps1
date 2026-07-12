<#
.SYNOPSIS
    TV_Server — guided installer (Windows).

.DESCRIPTION
    Choose IP-hiding (WARP), then this script generates .env, brings up the
    Docker stack, runs configure.ps1 (auto API key, CORS, FlareSolverr, tuning)
    and lets you add search indexers straight from the live Jackett — public
    ones add instantly, login/captcha trackers prompt as needed.

    If a server is already installed here, it instead offers REPAIR / DELETE /
    QUIT. UI language: English / Українська / Русский.

    Double-click install.bat, or run:  ./install.ps1
    Safe to re-run — it's idempotent.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Test-Cmd { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Set-EnvValue { param([string]$Path,[string]$Key,[string]$Value)
    $lines = if (Test-Path $Path) { Get-Content -LiteralPath $Path } else { @() }
    if ($lines -match "(?m)^$Key=") {
        $lines = $lines -replace "(?m)^$([regex]::Escape($Key))=.*$", "$Key=$Value"
    } else { $lines += "$Key=$Value" }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
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
                $line = "  {0,-8}{1}" -f $Options[$i].Key, $Options[$i].Desc
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
        & $DC[0] @($DC[1..($DC.Count-1)]) -f $f down -v --remove-orphans *> $null
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue jackett_config, torrserver_data, warp, .env
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
    repairing='Repairing existing installation...'; cl_title='TV_Server - core (TorrServer + Jackett + FlareSolverr) is always installed'
    warp_item='Hide IP for P2P (Cloudflare WARP)'; warp_gen='Generating a free Cloudflare WARP profile...'
    warp_ok='WARP profile generated.'; warp_parsefail='Could not parse WARP profile - set WARP_PRIVATE_KEY in .env manually.'
    warp_genfail='WARP profile generation failed - set WARP keys in .env later.'; starting='Starting containers ({0})...'
    configuring='Configuring services...'; ask_idx='Add search indexers from Jackett now? [Y/n]'
    idx_nopy='To add indexers, open Jackett at http://localhost:9117 (or install Python and re-run).'
    done='Done.'; repaired='Repaired.'; point='Point Lampa at your server:'; apilabel='API key'
    paste='(paste it into Lampa -> Parser/Jackett)'; ipon='IP hiding : ON'; reminder='Reminder: for WAN access, forward TCP+UDP port 42116 on your router.'
  }
  uk = @{
    lang_title='Language / Мова / Язык'; installed_title='Медіасервер уже встановлено в цій папці'
    d_repair='Перевстановити конфіг і перезапустити стек'; d_delete='Зупинити й видалити контейнери + дані'; d_quit='Вийти без змін'
    nothing='Немає що робити.'; del_confirm="Видаляє контейнери, томи ТА дані (jackett_config, torrserver_data, warp, .env). Введіть 'delete' для підтвердження"
    del_cancel='Скасовано - нічого не видалено.'; removing='Видалення медіасервера...'
    removed='Видалено контейнери, томи й дані. Запустіть install знову для налаштування.'
    repairing='Ремонт наявної інсталяції...'; cl_title='TV_Server - ядро (TorrServer + Jackett + FlareSolverr) ставиться завжди'
    warp_item='Приховати IP для P2P (Cloudflare WARP)'; warp_gen='Генерація безкоштовного профілю Cloudflare WARP...'
    warp_ok='Профіль WARP згенеровано.'; warp_parsefail='Не вдалося розібрати профіль WARP - впишіть WARP_PRIVATE_KEY у .env вручну.'
    warp_genfail='Не вдалося згенерувати профіль WARP - впишіть ключі WARP у .env пізніше.'; starting='Запуск контейнерів ({0})...'
    configuring='Налаштування сервісів...'; ask_idx='Додати пошукові індексатори з Jackett зараз? [Y/n]'
    idx_nopy='Щоб додати індексатори, відкрийте Jackett http://localhost:9117 (або встановіть Python і запустіть знову).'
    done='Готово.'; repaired='Відремонтовано.'; point='Вкажіть у Lampa адресу сервера:'; apilabel='API-ключ'
    paste='(вставте в Lampa -> Парсер/Jackett)'; ipon='Приховування IP: УВІМК'; reminder='Нагадування: для доступу з інтернету пробросьте TCP+UDP порт 42116 на роутері.'
  }
  ru = @{
    lang_title='Language / Мова / Язык'; installed_title='Медиасервер уже установлен в этой папке'
    d_repair='Переустановить конфиг и перезапустить стек'; d_delete='Остановить и удалить контейнеры + данные'; d_quit='Выйти без изменений'
    nothing='Нечего делать.'; del_confirm="Удаляет контейнеры, тома И данные (jackett_config, torrserver_data, warp, .env). Введите 'delete' для подтверждения"
    del_cancel='Отменено - ничего не удалено.'; removing='Удаление медиасервера...'
    removed='Удалены контейнеры, тома и данные. Запустите install снова для установки.'
    repairing='Ремонт существующей установки...'; cl_title='TV_Server - ядро (TorrServer + Jackett + FlareSolverr) ставится всегда'
    warp_item='Скрыть IP для P2P (Cloudflare WARP)'; warp_gen='Генерация бесплатного профиля Cloudflare WARP...'
    warp_ok='Профиль WARP сгенерирован.'; warp_parsefail='Не удалось разобрать профиль WARP - впишите WARP_PRIVATE_KEY в .env вручную.'
    warp_genfail='Не удалось сгенерировать профиль WARP - впишите ключи WARP в .env позже.'; starting='Запуск контейнеров ({0})...'
    configuring='Настройка сервисов...'; ask_idx='Добавить поисковые индексаторы из Jackett сейчас? [Y/n]'
    idx_nopy='Чтобы добавить индексаторы, откройте Jackett http://localhost:9117 (или установите Python и запустите снова).'
    done='Готово.'; repaired='Отремонтировано.'; point='Укажите в Lampa адрес сервера:'; apilabel='API-ключ'
    paste='(вставьте в Lampa -> Парсер/Jackett)'; ipon='Скрытие IP: ВКЛ'; reminder='Напоминание: для доступа из интернета пробросьте TCP+UDP порт 42116 на роутере.'
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
$pick = Show-Menu -Title (L 'lang_title') -Options @(
    [pscustomobject]@{ Key = 'EN'; Desc = 'English' }
    [pscustomobject]@{ Key = 'UK'; Desc = 'Українська' }
    [pscustomobject]@{ Key = 'RU'; Desc = 'Русский' }
)
switch ($pick) { 'EN' { $script:Lang = 'en' } 'UK' { $script:Lang = 'uk' } 'RU' { $script:Lang = 'ru' } }

# --- Existing installation? offer REPAIR / DELETE / QUIT --------------------
$mode = 'install'
if (Test-Installed) {
    $act = Show-Menu -Title (L 'installed_title') -Options @(
        [pscustomobject]@{ Key = 'REPAIR'; Desc = (L 'd_repair') }
        [pscustomobject]@{ Key = 'DELETE'; Desc = (L 'd_delete') }
        [pscustomobject]@{ Key = 'QUIT';   Desc = (L 'd_quit') }
    )
    Clear-Host
    switch ($act) {
        'QUIT'   { Write-Host (L 'nothing') -ForegroundColor Cyan; return }
        'DELETE' { Remove-Install -DC $DC; return }
        'REPAIR' { $mode = 'repair' }
    }
}

$wantWarp = $false
if ($mode -eq 'install') {
    Clear-Host
    Write-Host (L 'cl_title') -ForegroundColor Cyan
    $a = Read-Host ((L 'warp_item') + "? [y/N]")
    if ($a -match '^(y|т|д)') { $wantWarp = $true }
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }

    if ($wantWarp) {
        Write-Host "`n$(L 'warp_gen')" -ForegroundColor Cyan
        $gen = 'apk add --no-cache curl >/dev/null 2>&1 && curl -sL -o /wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 && chmod +x /wgcf && cd /tmp && /wgcf register --accept-tos >/dev/null 2>&1 && /wgcf generate >/dev/null 2>&1 && cat wgcf-profile.conf'
        try {
            $warpProfile = docker run --rm alpine sh -c $gen 2>$null
            $key  = ($warpProfile | Select-String 'PrivateKey').ToString().Split('=',2)[1].Trim()
            $addr = ($warpProfile | Select-String 'Address').ToString().Split('=',2)[1].Trim()
            if ($key) {
                Set-EnvValue .env 'WARP_PRIVATE_KEY' $key
                Set-EnvValue .env 'WARP_ADDRESS_V4' $addr
                Write-Host "  + $(L 'warp_ok')" -ForegroundColor Green
            } else { Write-Warning (L 'warp_parsefail') }
        } catch { Write-Warning (L 'warp_genfail') }
    }
} else {
    Write-Host (L 'repairing') -ForegroundColor Cyan
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    $warpInEnv = [bool](Get-Content .env | Where-Object { $_ -match '^WARP_PRIVATE_KEY=.+' })
    $warpRunning = (docker ps -a --format '{{.Names}}' 2>$null) -contains 'warp'
    $wantWarp = $warpInEnv -or $warpRunning
}

# --- Bring up the stack -----------------------------------------------------
$composeFile = if ($wantWarp) { 'docker-compose.warp.yml' } else { 'docker-compose.yml' }
Write-Host ("`n" + ((L 'starting') -f $composeFile)) -ForegroundColor Cyan
& $DC[0] @($DC[1..($DC.Count-1)]) -f $composeFile up -d

# --- Configure (auto API key, CORS, FlareSolverr, TorrServer tuning) --------
Write-Host "`n$(L 'configuring')" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'configure.ps1')

$apiKey = try { (Get-Content -Raw 'jackett_config/Jackett/ServerConfig.json' | ConvertFrom-Json).APIKey } catch { '' }

# --- Add search indexers from the live Jackett ------------------------------
if ($apiKey) {
    $py = if (Test-Cmd python) { 'python' } elseif (Test-Cmd py) { 'py' } else { $null }
    if ($py) {
        $ans = Read-Host (L 'ask_idx')
        if ($ans -notmatch '^(n|н)') {
            & $py (Join-Path $PSScriptRoot 'lib/setup_helpers.py') add-indexers 'http://127.0.0.1:9117' $apiKey --lang $script:Lang
        }
    } else {
        Write-Host ("  " + (L 'idx_nopy')) -ForegroundColor DarkGray
    }
}

# --- Summary ----------------------------------------------------------------
$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' -and
                   $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Hyper-V' } |
    Select-Object -First 1).IPAddress
if (-not $lan) { $lan = '<PC-IP>' }

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

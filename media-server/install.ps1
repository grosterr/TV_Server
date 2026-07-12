<#
.SYNOPSIS
    TV_Server — guided installer (Windows).

.DESCRIPTION
    Pick components with a checkbox menu (WARP IP-hiding, private trackers),
    then this script:
      * generates .env for you;
      * brings up the Docker stack (WARP variant if you chose IP-hiding);
      * runs configure.ps1 — which auto-reads the Jackett API key, enables
        CORS, links FlareSolverr, tunes TorrServer and adds your trackers;
      * prints ready-to-paste Lampa URLs with your LAN IP.

    If a server is already installed here, it instead offers REPAIR (re-apply
    config and restart), DELETE (remove containers, volumes and data) or QUIT.

    Double-click install.bat, or run:  ./install.ps1
    Safe to re-run — it's idempotent.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# --- Tracker registry (mirror of configure.ps1) -----------------------------
$Trackers = @(
    @{ Tag = 'toloka';    Label = 'Toloka.to';     UserVar = 'TOLOKA_USER';    PassVar = 'TOLOKA_PASS' }
    @{ Tag = 'rutracker'; Label = 'RuTracker.org'; UserVar = 'RUTRACKER_USER'; PassVar = 'RUTRACKER_PASS' }
)

function Test-Cmd { param($Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# --- Checkbox TUI (arrows to move, Space to toggle, Enter to confirm) --------
function Show-Checklist {
    param([string]$Title, [object[]]$Items)   # each: @{ Label=..; Checked=$false }
    $idx = 0
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            Clear-Host
            Write-Host $Title -ForegroundColor Cyan
            Write-Host "(↑/↓ move · Space toggle · Enter confirm)`n" -ForegroundColor DarkGray
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $mark = if ($Items[$i].Checked) { '[x]' } else { '[ ]' }
                if ($i -eq $idx) {
                    Write-Host (" > $mark " + $Items[$i].Label) -ForegroundColor Black -BackgroundColor Gray
                } else {
                    Write-Host ("   $mark " + $Items[$i].Label)
                }
            }
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $idx = ($idx - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $idx = ($idx + 1) % $Items.Count }
                'Spacebar'  { $Items[$idx].Checked = -not $Items[$idx].Checked }
                'Enter'     { return $Items }
                'Escape'    { throw 'Cancelled.' }
            }
        }
    } finally { [Console]::CursorVisible = $true }
}

function Read-Plain { param([string]$Prompt)
    $sec = Read-Host -Prompt $Prompt -AsSecureString
    [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Set-EnvValue { param([string]$Path,[string]$Key,[string]$Value)
    $lines = if (Test-Path $Path) { Get-Content -LiteralPath $Path } else { @() }
    if ($lines -match "(?m)^$Key=") {
        $lines = $lines -replace "(?m)^$([regex]::Escape($Key))=.*$", "$Key=$Value"
    } else {
        $lines += "$Key=$Value"
    }
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
            Write-Host "(↑/↓ move · Enter select)`n" -ForegroundColor DarkGray
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
    $confirm = Read-Host "This removes containers, volumes AND data (jackett_config, torrserver_data, warp, .env). Type 'delete' to confirm"
    if ($confirm -ne 'delete') { Write-Host "Cancelled - nothing removed." -ForegroundColor Cyan; return }
    Write-Host "Removing the media server..." -ForegroundColor Cyan
    foreach ($f in 'docker-compose.warp.yml','docker-compose.yml') {
        & $DC[0] @($DC[1..($DC.Count-1)]) -f $f down -v --remove-orphans *> $null
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue jackett_config, torrserver_data, warp, .env
    Write-Host "  + Removed containers, volumes and data. Re-run install to set up again." -ForegroundColor Green
}

# --- Preflight --------------------------------------------------------------
if (-not (Test-Cmd docker)) { throw "Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" }
# Native commands don't throw — check $LASTEXITCODE, not try/catch.
docker compose version *> $null
if ($LASTEXITCODE -eq 0)          { $DC = @('docker','compose') }
elseif (Test-Cmd docker-compose)  { $DC = @('docker-compose') }
else { throw "Docker Compose not found." }
docker info *> $null
if ($LASTEXITCODE -ne 0) { throw "Docker is installed but the daemon isn't running. Start Docker Desktop and retry." }

# --- Existing installation? offer REPAIR / DELETE / QUIT --------------------
$mode = 'install'
if (Test-Installed) {
    $act = Show-Menu -Title "TV_Server - a media server is already installed here" -Options @(
        [pscustomobject]@{ Key = 'REPAIR'; Desc = 'Re-apply config and restart the stack' }
        [pscustomobject]@{ Key = 'DELETE'; Desc = 'Stop and remove containers + data' }
        [pscustomobject]@{ Key = 'QUIT';   Desc = 'Exit without changes' }
    )
    Clear-Host
    switch ($act) {
        'QUIT'   { Write-Host "Nothing to do." -ForegroundColor Cyan; return }
        'DELETE' { Remove-Install -DC $DC; return }
        'REPAIR' { $mode = 'repair' }
    }
}

$wantWarp = $false
if ($mode -eq 'install') {
    # --- Component selection ------------------------------------------------
    $menu = @( [pscustomobject]@{ Label = 'Hide IP for P2P (Cloudflare WARP)'; Checked = $false; Tag = 'warp' } )
    foreach ($t in $Trackers) { $menu += [pscustomobject]@{ Label = "$($t.Label) (private tracker)"; Checked = $false; Tag = $t.Tag } }
    $result = Show-Checklist -Title "TV_Server installer — core (TorrServer + Jackett + FlareSolverr) is always installed" -Items $menu
    Clear-Host

    $wantWarp = ($result | Where-Object Tag -eq 'warp').Checked
    $selected = ($result | Where-Object { $_.Checked -and $_.Tag -ne 'warp' }).Tag

    # --- Credentials --------------------------------------------------------
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    foreach ($t in $Trackers) {
        if ($selected -contains $t.Tag) {
            Write-Host "`n$($t.Label):" -ForegroundColor Cyan
            $u = Read-Host "  username / e-mail"
            $p = Read-Plain "  password"
            Set-EnvValue .env $t.UserVar $u
            Set-EnvValue .env $t.PassVar $p
        }
    }

    # --- WARP profile -------------------------------------------------------
    if ($wantWarp) {
        Write-Host "`nGenerating a free Cloudflare WARP profile..." -ForegroundColor Cyan
        $gen = 'apk add --no-cache curl >/dev/null 2>&1 && curl -sL -o /wgcf https://github.com/ViRb3/wgcf/releases/download/v2.2.22/wgcf_2.2.22_linux_amd64 && chmod +x /wgcf && cd /tmp && /wgcf register --accept-tos >/dev/null 2>&1 && /wgcf generate >/dev/null 2>&1 && cat wgcf-profile.conf'
        try {
            $profile = docker run --rm alpine sh -c $gen 2>$null
            $key  = ($profile | Select-String 'PrivateKey').ToString().Split('=',2)[1].Trim()
            $addr = ($profile | Select-String 'Address').ToString().Split('=',2)[1].Trim()
            if ($key) {
                Set-EnvValue .env 'WARP_PRIVATE_KEY' $key
                Set-EnvValue .env 'WARP_ADDRESS_V4' $addr
                Write-Host "  + WARP profile generated." -ForegroundColor Green
            } else { Write-Warning "Could not parse WARP profile — set WARP_PRIVATE_KEY in .env manually." }
        } catch { Write-Warning "WARP profile generation failed — set WARP keys in .env later." }
    }
} else {
    # --- Repair: reuse the existing .env, keep the same WARP choice ----------
    Write-Host "Repairing existing installation..." -ForegroundColor Cyan
    if (-not (Test-Path .env)) { Copy-Item .env.example .env }
    $warpInEnv = [bool](Get-Content .env | Where-Object { $_ -match '^WARP_PRIVATE_KEY=.+' })
    $warpRunning = (docker ps -a --format '{{.Names}}' 2>$null) -contains 'warp'
    $wantWarp = $warpInEnv -or $warpRunning
}

# --- Bring up the stack -----------------------------------------------------
$composeFile = if ($wantWarp) { 'docker-compose.warp.yml' } else { 'docker-compose.yml' }
Write-Host "`nStarting containers ($composeFile)..." -ForegroundColor Cyan
& $DC[0] @($DC[1..($DC.Count-1)]) -f $composeFile up -d

# --- Configure (auto API key, CORS, FlareSolverr, tuning, trackers) ---------
Write-Host "`nConfiguring services..." -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'configure.ps1')

# --- Summary ----------------------------------------------------------------
$lan = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' -and
                   $_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Hyper-V' } |
    Select-Object -First 1).IPAddress
if (-not $lan) { $lan = '<PC-IP>' }

$apiKey = try { (Get-Content -Raw 'jackett_config/Jackett/ServerConfig.json' | ConvertFrom-Json).APIKey } catch { '' }

$headline = if ($mode -eq 'repair') { 'Repaired.' } else { 'Done.' }
Write-Host "`n$headline Point Lampa at your server:" -ForegroundColor Cyan
Write-Host "  TorrServer: http://$lan`:8090" -ForegroundColor Green
Write-Host "  Jackett   : http://$lan`:9117" -ForegroundColor Green
if ($apiKey) {
    Write-Host "  API key   : $apiKey" -ForegroundColor Green
    Write-Host "  (paste it into Lampa -> Parser/Jackett)" -ForegroundColor DarkGray
}
if ($wantWarp) {
    Write-Host "  IP hiding : ON — verify with: docker exec warp wget -qO- https://api.ipify.org" -ForegroundColor Green
}
Write-Host "  Reminder: for WAN access, forward TCP+UDP port 42116 on your router." -ForegroundColor DarkGray

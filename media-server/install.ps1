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

# --- Preflight --------------------------------------------------------------
if (-not (Test-Cmd docker)) { throw "Docker not found. Install Docker Desktop: https://www.docker.com/products/docker-desktop/" }
try { docker compose version *> $null; $DC = @('docker','compose') }
catch { if (Test-Cmd docker-compose) { $DC = @('docker-compose') } else { throw "Docker Compose not found." } }

# --- Component selection ----------------------------------------------------
$menu = @( [pscustomobject]@{ Label = 'Hide IP for P2P (Cloudflare WARP)'; Checked = $false; Tag = 'warp' } )
foreach ($t in $Trackers) { $menu += [pscustomobject]@{ Label = "$($t.Label) (private tracker)"; Checked = $false; Tag = $t.Tag } }
$result = Show-Checklist -Title "TV_Server installer — core (TorrServer + Jackett + FlareSolverr) is always installed" -Items $menu
Clear-Host

$wantWarp = ($result | Where-Object Tag -eq 'warp').Checked
$selected = ($result | Where-Object { $_.Checked -and $_.Tag -ne 'warp' }).Tag

# --- Credentials ------------------------------------------------------------
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

# --- WARP profile -----------------------------------------------------------
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

Write-Host "`nDone. Point Lampa at your server:" -ForegroundColor Cyan
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

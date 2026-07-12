<#
.SYNOPSIS
    Configures the media server after `docker compose up -d`:
      * applies TorrServer performance tuning (RAM cache, connection limit);
      * adds/updates every Jackett tracker listed in $Trackers using
        credentials from .env.

.DESCRIPTION
    Idempotent — safe to run repeatedly. Reads all secrets from .env, so no
    passwords or API keys live in this file. Skips any tracker whose
    credentials are missing.

.EXAMPLE
    ./configure.ps1
    ./configure.ps1 -JackettUrl http://127.0.0.1:9117 -TorrServerUrl http://127.0.0.1:8090
#>
[CmdletBinding()]
param(
    [string]$EnvFile       = (Join-Path $PSScriptRoot '.env'),
    [string]$JackettUrl    = 'http://127.0.0.1:9117',
    [string]$TorrServerUrl = 'http://127.0.0.1:8090',
    [int]   $TimeoutSec    = 60
)

$ErrorActionPreference = 'Stop'

# --- Tracker registry -------------------------------------------------------
# To support a new private tracker, add one row here — no other code changes.
$Trackers = @(
    @{ Id = 'toloka';    Site = 'https://toloka.to/';    UserVar = 'TOLOKA_USER';    PassVar = 'TOLOKA_PASS' }
    @{ Id = 'rutracker'; Site = 'https://rutracker.org/'; UserVar = 'RUTRACKER_USER'; PassVar = 'RUTRACKER_PASS' }
)

# --- Helpers ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) {
        Write-Warning "No .env found at $Path — credentials will be empty."
        return $vars
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Count -ne 2) { continue }
        $name  = $pair[0].Trim()
        $value = $pair[1].Trim().Trim('"', "'")   # strip whitespace + optional quotes
        if ($name) { $vars[$name] = $value }
    }
    return $vars
}

function Wait-ForService {
    param([string]$Url, [string]$Name, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 5 -UseBasicParsing | Out-Null
            return $true
        } catch {
            # HTTP errors still mean the port answered — service is up.
            if ($_.Exception.Response) { return $true }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Set-JackettIndexer {
    param([hashtable]$Tracker, [string]$JackettUrl, [string]$ApiKey, [hashtable]$Env)

    $user = $Env[$Tracker.UserVar]
    $pass = $Env[$Tracker.PassVar]
    if (-not $user -or -not $pass) {
        Write-Host "  - $($Tracker.Id): skipped (no credentials in .env)" -ForegroundColor Yellow
        return
    }

    $config = @(
        @{ id = 'sitelink'; value = $Tracker.Site }
        @{ id = 'username'; value = $user }
        @{ id = 'password'; value = $pass }
    )
    $uri = "$JackettUrl/api/v2.0/indexers/$($Tracker.Id)/config?apikey=$ApiKey"
    try {
        Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json' `
            -Body ($config | ConvertTo-Json) | Out-Null
        Write-Host "  + $($Tracker.Id): configured" -ForegroundColor Green
    } catch {
        Write-Host "  ! $($Tracker.Id): failed — $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-TorrServerTuning {
    param([string]$TorrServerUrl, [long]$CacheSize, [int]$ConnLimit, [int]$PeerPort, [int]$DisconnectTimeout)
    try {
        $current = Invoke-RestMethod -Uri "$TorrServerUrl/settings" -Method Post `
            -ContentType 'application/json' -Body (@{ action = 'get' } | ConvertTo-Json)
    } catch {
        Write-Host "  ! TorrServer settings unreachable — $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $current.CacheSize                = $CacheSize
    $current.ConnectionsLimit         = $ConnLimit
    $current.PeersListenPort          = $PeerPort
    $current.TorrentDisconnectTimeout = $DisconnectTimeout
    try {
        Invoke-RestMethod -Uri "$TorrServerUrl/settings" -Method Post -ContentType 'application/json' `
            -Body (@{ action = 'set'; sets = $current } | ConvertTo-Json -Depth 5) | Out-Null
        $gib = [math]::Round($CacheSize / 1GB, 2)
        Write-Host "  + TorrServer: cache ${gib} GiB, $ConnLimit connections, peer port $PeerPort, disconnect timeout ${DisconnectTimeout}s" -ForegroundColor Green
    } catch {
        Write-Host "  ! TorrServer tuning failed — $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-JackettFlareSolverr {
    # Point Jackett at the FlareSolverr container so it can index
    # Cloudflare-protected trackers (1337x, etc). Patches ServerConfig.json
    # directly (Jackett has no public API for this) and restarts if changed.
    param([string]$Url)
    $cfgPath = Join-Path $PSScriptRoot 'jackett_config/Jackett/ServerConfig.json'
    if (-not (Test-Path $cfgPath)) {
        Write-Host "  - FlareSolverr: Jackett config not found yet — skipped" -ForegroundColor Yellow
        return
    }
    $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
    # AllowCORS lets the Lampa web UI (a different origin) read Jackett's
    # responses — without it the TV shows "parser not responding" (see README FAQ).
    $corsOk = [bool]$cfg.AllowCORS
    if ($cfg.FlareSolverrUrl -eq $Url -and $corsOk) {
        Write-Host "  = FlareSolverr + CORS: already set ($Url)" -ForegroundColor DarkGray
        return
    }
    $cfg.FlareSolverrUrl = $Url
    if (-not $corsOk) {
        if ($cfg.PSObject.Properties.Name -contains 'AllowCORS') { $cfg.AllowCORS = $true }
        else { $cfg | Add-Member -NotePropertyName AllowCORS -NotePropertyValue $true }
    }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath -Encoding UTF8
    try {
        docker restart jackett | Out-Null
        Write-Host "  + FlareSolverr linked + CORS enabled ($Url), Jackett restarted" -ForegroundColor Green
    } catch {
        Write-Host "  + FlareSolverr + CORS set in config — restart Jackett to apply" -ForegroundColor Green
    }
}

# --- Main -------------------------------------------------------------------
$env = Import-DotEnv -Path $EnvFile

$apiKey = $env['JACKETT_APIKEY']
if (-not $apiKey) {
    $serverConfig = Join-Path $PSScriptRoot 'jackett_config/Jackett/ServerConfig.json'
    if (Test-Path $serverConfig) {
        $apiKey = (Get-Content -Raw $serverConfig | ConvertFrom-Json).APIKey
    }
}
if (-not $apiKey) { throw "Jackett API key not found. Set JACKETT_APIKEY in .env." }

Write-Host "Waiting for services..." -ForegroundColor Cyan
if (-not (Wait-ForService -Url $JackettUrl -Name 'Jackett' -TimeoutSec $TimeoutSec)) {
    throw "Jackett did not respond at $JackettUrl within ${TimeoutSec}s. Is `docker compose up -d` running?"
}

Write-Host "Tuning TorrServer:" -ForegroundColor Cyan
$cache = if ($env['TORRSERVER_CACHE_SIZE']) { [long]$env['TORRSERVER_CACHE_SIZE'] } else { 2147483648 }
$conn  = if ($env['TORRSERVER_CONN_LIMIT'])  { [int]$env['TORRSERVER_CONN_LIMIT'] }   else { 1000 }
$port  = if ($env['TORRSERVER_PEER_PORT'])   { [int]$env['TORRSERVER_PEER_PORT'] }    else { 42116 }
$dct   = if ($env['TORRSERVER_DISCONNECT_TIMEOUT']) { [int]$env['TORRSERVER_DISCONNECT_TIMEOUT'] } else { 3600 }
if (Wait-ForService -Url $TorrServerUrl -Name 'TorrServer' -TimeoutSec 10) {
    Set-TorrServerTuning -TorrServerUrl $TorrServerUrl -CacheSize $cache -ConnLimit $conn -PeerPort $port -DisconnectTimeout $dct
} else {
    Write-Host "  ! TorrServer not reachable at $TorrServerUrl — skipped" -ForegroundColor Yellow
}

Write-Host "Configuring Jackett trackers:" -ForegroundColor Cyan
foreach ($tracker in $Trackers) {
    Set-JackettIndexer -Tracker $tracker -JackettUrl $JackettUrl -ApiKey $apiKey -Env $env
}

# Done last: patching FlareSolverr restarts Jackett, so keep it after the
# tracker API calls that need Jackett up.
Write-Host "Linking FlareSolverr (Cloudflare bypass):" -ForegroundColor Cyan
$fsUrl = if ($env['JACKETT_FLARESOLVERR_URL']) { $env['JACKETT_FLARESOLVERR_URL'] } else { 'http://flaresolverr:8191' }
Set-JackettFlareSolverr -Url $fsUrl

Write-Host "Done." -ForegroundColor Cyan

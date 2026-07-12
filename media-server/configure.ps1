<#
.SYNOPSIS
    Configures the media server after `docker compose up -d`:
      * applies TorrServer performance tuning (RAM cache, connection limit);
      * enables CORS and links FlareSolverr in Jackett.

    Search indexers are added by the user in the Jackett web UI, which
    install.ps1 / install.sh open automatically after configuring.

.DESCRIPTION
    Idempotent -- safe to run repeatedly. Reads tuning values from .env, so no
    secrets live in this file.

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

# --- Helpers ----------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) {
        Write-Warning "No .env found at $Path -- credentials will be empty."
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
            # HTTP errors still mean the port answered -- service is up.
            if ($_.Exception.Response) { return $true }
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

function Set-TorrServerTuning {
    param([string]$TorrServerUrl, [long]$CacheSize, [int]$ConnLimit, [int]$PeerPort, [int]$DisconnectTimeout)
    try {
        $current = Invoke-RestMethod -Uri "$TorrServerUrl/settings" -Method Post `
            -ContentType 'application/json' -Body (@{ action = 'get' } | ConvertTo-Json)
    } catch {
        Write-Host "  ! TorrServer settings unreachable -- $($_.Exception.Message)" -ForegroundColor Red
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
        Write-Host "  ! TorrServer tuning failed -- $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-JackettFlareSolverr {
    # Patch Jackett's ServerConfig.json:
    #   - FlareSolverrUrl  -> point at the FlareSolverr container
    #   - AllowCORS        -> let Lampa (cross-origin) read Jackett responses
    #   - LocalBindAddress -> '*' so Docker port-mapping works (127.0.0.1
    #     inside a container rejects traffic from the host)
    #   - AllowExternal    -> required together with the wildcard bind
    param([string]$Url)
    $cfgPath = Join-Path $PSScriptRoot 'jackett_config/Jackett/ServerConfig.json'
    if (-not (Test-Path $cfgPath)) {
        Write-Host "  - FlareSolverr: Jackett config not found yet -- skipped" -ForegroundColor Yellow
        return
    }
    $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
    $changed = $false

    # FlareSolverr URL
    if ($cfg.FlareSolverrUrl -ne $Url) {
        $cfg.FlareSolverrUrl = $Url
        $changed = $true
    }
    # CORS -- lets the Lampa web UI (a different origin) read Jackett's
    # responses -- without it the TV shows "parser not responding" (see README FAQ).
    if (-not [bool]$cfg.AllowCORS) {
        if ($cfg.PSObject.Properties.Name -contains 'AllowCORS') { $cfg.AllowCORS = $true }
        else { $cfg | Add-Member -NotePropertyName AllowCORS -NotePropertyValue $true }
        $changed = $true
    }
    # LocalBindAddress -- must be '*' inside Docker so port-mapped traffic
    # (which arrives on the container's external NIC, not loopback) is accepted.
    if ($cfg.LocalBindAddress -eq '127.0.0.1') {
        $cfg.LocalBindAddress = '*'
        $changed = $true
    }
    # AllowExternal -- required alongside the wildcard bind.
    if (-not [bool]$cfg.AllowExternal) {
        if ($cfg.PSObject.Properties.Name -contains 'AllowExternal') { $cfg.AllowExternal = $true }
        else { $cfg | Add-Member -NotePropertyName AllowExternal -NotePropertyValue $true }
        $changed = $true
    }

    if (-not $changed) {
        Write-Host "  = Jackett config: already OK (FlareSolverr, CORS, bind)" -ForegroundColor DarkGray
        return
    }
    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $cfgPath -Encoding UTF8
    try {
        docker restart jackett | Out-Null
        Write-Host "  + Jackett patched (FlareSolverr, CORS, bind *), restarted" -ForegroundColor Green
    } catch {
        Write-Host "  + Jackett config patched -- restart Jackett to apply" -ForegroundColor Green
    }
}

# --- Main -------------------------------------------------------------------
$env = Import-DotEnv -Path $EnvFile

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
    Write-Host "  ! TorrServer not reachable at $TorrServerUrl -- skipped" -ForegroundColor Yellow
}

Write-Host "Linking FlareSolverr (Cloudflare bypass):" -ForegroundColor Cyan
$fsUrl = if ($env['JACKETT_FLARESOLVERR_URL']) { $env['JACKETT_FLARESOLVERR_URL'] } else { 'http://flaresolverr:8191' }
Set-JackettFlareSolverr -Url $fsUrl
# Jackett may have just restarted above -- wait until it serves again so callers
# (e.g. the indexer-add step) don't hit it mid-restart.
Wait-ForService -Url $JackettUrl -Name 'Jackett' -TimeoutSec 30 | Out-Null

Write-Host "Done." -ForegroundColor Cyan

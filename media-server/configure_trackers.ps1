$envFile = ".\.env"
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match "^[^#].*=.*" } | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        Set-Item -Path Env:\$name -Value $value
    }
}

$apiKey = "cbwv7lcs6gwic25fmeyy2g1fa9svn9h8"

if ($env:TOLOKA_USER -and $env:TOLOKA_PASS) {
    Write-Host "Adding Toloka..."
    $bodyToloka = @"
[
    {"id":"sitelink","value":"https://toloka.to/"},
    {"id":"username","value":"$($env:TOLOKA_USER)"},
    {"id":"password","value":"$($env:TOLOKA_PASS)"}
]
"@
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:9117/api/v2.0/indexers/toloka/config?apikey=$apiKey" -Method Post -Body $bodyToloka -ContentType "application/json"
        Write-Host "Toloka added successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to add Toloka: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Skipping Toloka (credentials missing in .env)" -ForegroundColor Yellow
}

if ($env:RUTRACKER_USER -and $env:RUTRACKER_PASS) {
    Write-Host "Adding RuTracker..."
    $bodyRuTracker = @"
[
    {"id":"sitelink","value":"https://rutracker.org/"},
    {"id":"username","value":"$($env:RUTRACKER_USER)"},
    {"id":"password","value":"$($env:RUTRACKER_PASS)"}
]
"@
    try {
        Invoke-RestMethod -Uri "http://127.0.0.1:9117/api/v2.0/indexers/rutracker/config?apikey=$apiKey" -Method Post -Body $bodyRuTracker -ContentType "application/json"
        Write-Host "RuTracker added successfully!" -ForegroundColor Green
    } catch {
        Write-Host "Failed to add RuTracker: $_" -ForegroundColor Red
    }
} else {
    Write-Host "Skipping RuTracker (credentials missing in .env)" -ForegroundColor Yellow
}

Write-Host "Done!"

<#
    OVH EU VPS stock check - GitHub Actions edition.

    Differences from the local Windows watcher:
      * no desktop toast, no polling loop - one shot per workflow run
      * the ntfy topic comes from an encrypted secret, never from config.json
      * state lives in state.json, committed back only when it actually changes
#>
$ErrorActionPreference = 'Stop'

$Root       = $PSScriptRoot
$ConfigPath = Join-Path $Root 'config.json'
$StatePath  = Join-Path $Root 'state.json'

$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$topic  = $env:NTFY_TOPIC
$server = if ($env:NTFY_SERVER) { $env:NTFY_SERVER } else { 'https://ntfy.sh' }
$email  = $env:NTFY_EMAIL

# Belt and braces: the topic is a secret and Actions masks it, but make sure we
# never widen that by echoing it ourselves.
if ($topic) { Write-Host "::add-mask::$topic" }

function Write-Summary {
    param([string]$Text)
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Text }
    Write-Host $Text
}

# ------------------------------------------------------------------ watched ---
$watched = [ordered]@{}
foreach ($p in $cfg.euDatacenters.PSObject.Properties) { $watched[$p.Name] = @{ Label = $p.Value; IsEu = $true } }
if ($cfg.notifyOnNonEu) {
    foreach ($p in $cfg.alsoWatchNonEu.PSObject.Properties) { $watched[$p.Name] = @{ Label = $p.Value; IsEu = $false } }
}

# -------------------------------------------------------------------- fetch ---
$uri = 'https://www.ovhcloud.com/eu/engine/api/v1/vps/order/rule/datacenter/?ovhSubsidiary={0}&planCode={1}' -f
    [uri]::EscapeDataString($cfg.ovhSubsidiary), [uri]::EscapeDataString($cfg.planCode)

$resp = $null
foreach ($attempt in 1..3) {
    try { $resp = Invoke-RestMethod -Uri $uri -Headers @{ Accept = 'application/json' } -TimeoutSec 45; break }
    catch {
        Write-Host "Attempt $attempt/3 failed: $($_.Exception.Message)"
        if ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
}
if ($null -eq $resp) {
    Write-Summary '## OVH check FAILED'
    Write-Summary 'Could not reach the OVH availability endpoint after 3 attempts.'
    exit 1
}

$dcs = @($resp.datacenters)
if ($dcs.Count -eq 0) {
    Write-Summary "## OVH check FAILED"
    Write-Summary "No datacenters returned for plan code ``$($cfg.planCode)`` - has OVH renamed it?"
    exit 1
}

# ----------------------------------------------------------------- evaluate ---
function Test-Available {
    param($dc)
    switch ($cfg.osFilter) {
        'linux'   { return $dc.linuxStatus   -eq 'available' }
        'windows' { return $dc.windowsStatus -eq 'available' }
        default   { return ($dc.status -eq 'available') -or ($dc.linuxStatus -eq 'available') -or ($dc.windowsStatus -eq 'available') }
    }
}

$hits = @()
foreach ($dc in ($dcs | Sort-Object code)) {
    if (-not $watched.Contains($dc.code)) { continue }
    if (Test-Available $dc) {
        $hits += [pscustomobject]@{ Code = $dc.code; Label = $watched[$dc.code].Label; IsEu = $watched[$dc.code].IsEu }
    }
}
$now = @($hits | ForEach-Object { $_.Code } | Sort-Object)

# Only the watched datacenters go into state, so unrelated regions flipping
# in and out of stock do not churn the committed file.
$watchedSummary = (($dcs | Where-Object { $watched.Contains($_.code) } | Sort-Object code |
    ForEach-Object { '{0}={1}' -f $_.code, $_.linuxStatus }) -join ' ')

# -------------------------------------------------------------------- state ---
$state = [pscustomobject]@{ lastAvailable = @(); lastNotified = $null; lastSummary = $null; keepalive = $null }
if (Test-Path -LiteralPath $StatePath) {
    try { $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { }
}
foreach ($f in 'lastAvailable', 'lastNotified', 'lastSummary', 'keepalive') {
    if ($null -eq $state.PSObject.Properties[$f]) { $state | Add-Member -NotePropertyName $f -NotePropertyValue $null }
}
$prev = @($state.lastAvailable)
$newCodes = @($now | Where-Object { $prev -notcontains $_ })

$shouldNotify = $false
$reason = ''
if ($hits.Count -gt 0) {
    if ($newCodes.Count -gt 0) { $shouldNotify = $true; $reason = 'new availability' }
    elseif ($state.lastNotified) {
        $hours = ([datetime]::UtcNow - ([datetime]::Parse($state.lastNotified)).ToUniversalTime()).TotalHours
        if ($hours -ge [double]$cfg.reNotifyAfterHours) { $shouldNotify = $true; $reason = 'still-available reminder' }
    }
}

# ------------------------------------------------------------------- notify ---
if ($shouldNotify) {
    $lines = $hits | ForEach-Object { '  * {0} - {1}{2}' -f $_.Code, $_.Label, $(if ($_.IsEu) { '' } else { ' [non-EU]' }) }
    $title = if ($hits.Count -eq 1) { "OVH: EU stock! $($hits[0].Label)" } else { "OVH: $($hits.Count) EU datacenters in stock" }
    $body  = (@("$($cfg.planCode) is available in:") + $lines +
              @('', 'Order now - stock moves fast:', $cfg.configuratorUrl, '', '(detected by the GitHub Actions backstop)')) -join "`n"

    if ([string]::IsNullOrWhiteSpace($topic)) {
        Write-Summary 'Stock found but NTFY_TOPIC secret is not set - no notification sent.'
    } else {
        $headers = @{ Title = $title; Priority = 'urgent'; Tags = 'rotating_light'; Click = $cfg.configuratorUrl }
        if (-not [string]::IsNullOrWhiteSpace($email)) { $headers['Email'] = $email }
        Invoke-RestMethod -Method Post -Uri "$server/$topic" -Headers $headers `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30 | Out-Null
        Write-Summary "## EU STOCK FOUND ($reason)"
        Write-Summary "Notification pushed for: $($now -join ', ')"
    }
    $state.lastAvailable = $now
    $state.lastNotified  = (Get-Date).ToUniversalTime().ToString('o')
} elseif ($hits.Count -eq 0) {
    Write-Summary "## No EU stock"
    $state.lastAvailable = @()
    $state.lastNotified  = $null
} else {
    Write-Summary "## EU stock still available (already notified)"
    $state.lastAvailable = $now
}

Write-Summary ''
Write-Summary '| Datacenter | Location | Linux |'
Write-Summary '|---|---|---|'
foreach ($dc in ($dcs | Where-Object { $watched.Contains($_.code) } | Sort-Object code)) {
    $mark = if ($dc.linuxStatus -eq 'available') { '**available**' } else { $dc.linuxStatus }
    Write-Summary ('| `{0}` | {1} | {2} |' -f $dc.code, $watched[$dc.code].Label, $mark)
}

$state.lastSummary = $watchedSummary
# Changes once a month, which guarantees a commit and stops GitHub disabling
# the schedule for repo inactivity (it does that after 60 days).
$state.keepalive = (Get-Date -Format 'yyyy-MM')

$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding utf8NoBOM

[CmdletBinding()]
param(
    [string]$HealthUri = 'http://127.0.0.1:3688/health',
    [string]$AppLog = (Join-Path $env:APPDATA 'ccx-desktop\logs\app.log'),
    [int]$TailLines = 5000,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$generatedAt = Get-Date

$healthError = ''
$health = $null
try {
    $health = Invoke-RestMethod -Uri $HealthUri -TimeoutSec 5
} catch {
    $healthError = $_.Exception.Message
}

$process = Get-Process -Name 'ccx-go' -ErrorAction SilentlyContinue | Select-Object -First 1
$listener = Get-NetTCPConnection -LocalPort 3688 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1

$logExists = Test-Path -LiteralPath $AppLog -PathType Leaf
$tail = @()
$logError = ''
if ($logExists) {
    try {
        $tail = Get-Content -LiteralPath $AppLog -Tail $TailLines -ErrorAction Stop
    } catch {
        $logError = $_.Exception.Message
    }
}

$counts = [ordered]@{
    success = @($tail | Where-Object { $_ -match '\[Responses-Stream\].*?Responses\s*流式响应完成' }).Count
    failover = @($tail | Where-Object { $_ -match '\[Responses-Failover\]' }).Count
    requestReceive = @($tail | Where-Object { $_ -match '\[Request-Receive\]' }).Count
    http429 = @($tail | Where-Object { $_ -match 'statusCode\s*=\s*429' }).Count
    http5xx = @($tail | Where-Object { $_ -match 'statusCode\s*=\s*5\d\d' }).Count
}

$healthy = $health -and ([string]$health.status -eq 'healthy') -and $listener
[pscustomobject]@{
    generatedAt = $generatedAt.ToString('yyyy-MM-ddTHH:mm:sszzz')
    healthy = [bool]$healthy
    health = if ($health) { $health } else { $null }
    healthError = $healthError
    process = if ($process) {
        [pscustomobject]@{
            id = $process.Id
            path = $process.Path
            startTime = $process.StartTime
            workingSetMB = [math]::Round($process.WorkingSet64 / 1MB, 1)
        }
    } else { $null }
    listener = if ($listener) { [pscustomobject]@{ localPort = $listener.LocalPort; owningProcess = $listener.OwningProcess } } else { $null }
    log = [pscustomobject]@{
        path = $AppLog
        exists = $logExists
        tailLines = $TailLines
        error = $logError
        sizeMB = if ($logExists) { [math]::Round((Get-Item -LiteralPath $AppLog).Length / 1MB, 1) } else { 0 }
    }
    counts = $counts
} | ForEach-Object {
    if ($Json) { $_ | ConvertTo-Json -Depth 6 } else { $_ }
}

[CmdletBinding()]
param(
    [string]$HealthUri = 'http://127.0.0.1:3688/health',
    [string]$ModelsUri = 'http://127.0.0.1:3688/v1/models',
    [string]$ProxyToken = '',
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
$health = Invoke-RestMethod -Uri $HealthUri -TimeoutSec $TimeoutSec
if ([string]$health.status -ne 'healthy') {
    throw "CCX is not healthy: $($health | ConvertTo-Json -Compress)"
}

$headers = @{}
if ($ProxyToken) {
    $headers['Authorization'] = "Bearer $ProxyToken"
}

$models = Invoke-RestMethod -Uri $ModelsUri -Headers $headers -TimeoutSec $TimeoutSec
[pscustomobject]@{
    status = 'healthy'
    version = if ($health.version.version) { $health.version.version } else { $health.version }
    modelCount = @($models.data).Count
    proxy = $HealthUri
} | ConvertTo-Json -Compress

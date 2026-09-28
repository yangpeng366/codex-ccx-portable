[CmdletBinding()]
param(
    [ValidateSet('never', 'on-request', 'on-failure', 'untrusted')]
    [string]$ApprovalPolicy = 'never',
    [ValidateSet('danger-full-access', 'workspace-write', 'read-only')]
    [string]$SandboxMode = 'danger-full-access',
    [string]$ProxyToken = '',
    [string]$CcxConfigPath = '',
    [string]$CcxBinaryPath = '',
    [string]$ModelCatalogPath = '',
    [switch]$SkipCodexInstall,
    [switch]$NoAutoStart,
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$privateDir = Join-Path $repoRoot 'payload\private'

function Assert-File {
    param([string]$Path, [string]$Description)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description not found: $Path"
    }
    return (Get-Item -LiteralPath $Path).FullName
}

function Backup-File {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $Path -Destination "$Path.bak-$stamp" -Force
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Wait-CcxHealth {
    param([string]$Uri, [int]$Seconds = 70)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri $Uri -TimeoutSec 3
            if ([string]$health.status -eq 'healthy') {
                return $health
            }
        } catch {
        }
        Start-Sleep -Seconds 2
    }
    throw "CCX did not become healthy at $Uri within $Seconds seconds"
}

function Update-CurrentPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Install-CodexCli {
    if (Get-Command codex -ErrorAction SilentlyContinue) { return }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
            & npm.cmd install -g '@openai/codex@latest'
            if ($LASTEXITCODE -ne 0) { throw "npm failed to install Codex with exit code $LASTEXITCODE" }
            Update-CurrentPath
        }
    } else {
        & winget.exe install --id OpenAI.Codex --exact --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget failed to install Codex with exit code $LASTEXITCODE" }
        Update-CurrentPath
    }
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        throw 'Codex CLI was not found after installation. Open a new terminal and rerun install.ps1.'
    }
}

if (-not $SkipCodexInstall) {
    Install-CodexCli
}

if (-not $CcxConfigPath) {
    $CcxConfigPath = Join-Path $privateDir 'ccx-config.json'
}
if (-not $CcxBinaryPath) {
    $installedBinary = 'C:\Program Files\CCX\CCX Desktop\ccx-go.exe'
    $CcxBinaryPath = if (Test-Path -LiteralPath (Join-Path $privateDir 'ccx-go.exe')) { Join-Path $privateDir 'ccx-go.exe' } else { $installedBinary }
}
if (-not $ModelCatalogPath) {
    $privateCatalog = Join-Path $privateDir 'ccx-model-catalog.json'
    $ModelCatalogPath = if (Test-Path -LiteralPath $privateCatalog) { $privateCatalog } else { '' }
}

$CcxConfigPath = Assert-File $CcxConfigPath 'CCX config'
$CcxBinaryPath = Assert-File $CcxBinaryPath 'CCX binary'
$configTemplate = Assert-File (Join-Path $repoRoot 'templates\config.template.toml') 'Codex config template'

if (-not $ProxyToken) {
    $tokenFile = Join-Path $privateDir 'proxy-token.txt'
    if (Test-Path -LiteralPath $tokenFile -PathType Leaf) {
        $ProxyToken = (Get-Content -LiteralPath $tokenFile -Raw).Trim()
    }
}
if (-not $ProxyToken) {
    throw 'ProxyToken is required. Run install.ps1 from a private bundle or pass -ProxyToken.'
}

$null = Get-Content -LiteralPath $CcxConfigPath -Raw | ConvertFrom-Json
$catalogMode = 'omitted'
if ($ModelCatalogPath) {
    $ModelCatalogPath = Assert-File $ModelCatalogPath 'Codex model catalog'
    $null = Get-Content -LiteralPath $ModelCatalogPath -Raw | ConvertFrom-Json
    $catalogMode = 'installed'
}

$codexDir = Join-Path $env:USERPROFILE '.codex'
$ccxInstallDir = Join-Path $env:LOCALAPPDATA 'Programs\CCX Desktop'
$ccxConfigDir = Join-Path $env:APPDATA 'ccx-desktop\.config'
$ccxTargetBinary = Join-Path $ccxInstallDir 'ccx-go.exe'
$codexConfigPath = Join-Path $codexDir 'config.toml'
$authPath = Join-Path $codexDir 'auth.json'
$catalogTargetPath = Join-Path $codexDir 'ccx-model-catalog.json'

New-Item -ItemType Directory -Force -Path $codexDir, $ccxInstallDir, $ccxConfigDir | Out-Null
Backup-File $codexConfigPath
Backup-File $authPath
Backup-File $catalogTargetPath
Backup-File (Join-Path $ccxConfigDir 'config.json')

try {
    Copy-Item -LiteralPath $CcxBinaryPath -Destination $ccxTargetBinary -Force
} catch {
    Get-Process -Name 'ccx-go' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $ccxTargetBinary } |
        Stop-Process -Force
    Start-Sleep -Seconds 1
    Copy-Item -LiteralPath $CcxBinaryPath -Destination $ccxTargetBinary -Force
}

Copy-Item -LiteralPath $CcxConfigPath -Destination (Join-Path $ccxConfigDir 'config.json') -Force

$codexConfig = Get-Content -LiteralPath $configTemplate -Raw
$codexConfig = $codexConfig.Replace('__APPROVAL_POLICY__', $ApprovalPolicy)
$codexConfig = $codexConfig.Replace('__SANDBOX_MODE__', $SandboxMode)
$codexConfig = $codexConfig.Replace('__CCX_PROXY_TOKEN__', $ProxyToken)
if ($ModelCatalogPath) {
    $escapedCatalog = $catalogTargetPath.Replace('\', '\\')
    $codexConfig = $codexConfig.Replace(
        '[features]',
        "model_catalog_json = `"$escapedCatalog`"`n`n[features]"
    )
}
Write-Utf8NoBom $codexConfigPath $codexConfig

$auth = [ordered]@{
    OPENAI_API_KEY = $ProxyToken
    auth_mode = 'apikey'
}
Write-Utf8NoBom $authPath (($auth | ConvertTo-Json) + [Environment]::NewLine)

if ($ModelCatalogPath) {
    Copy-Item -LiteralPath $ModelCatalogPath -Destination $catalogTargetPath -Force
} elseif (Test-Path -LiteralPath $catalogTargetPath) {
    Remove-Item -LiteralPath $catalogTargetPath -Force
}

$healthUri = 'http://127.0.0.1:3688/health'
$running = Get-Process -Name 'ccx-go' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $running) {
    Start-Process -FilePath $ccxTargetBinary -WorkingDirectory $ccxInstallDir -WindowStyle Hidden
}

$health = Wait-CcxHealth -Uri $healthUri

if (-not $NoAutoStart) {
    $taskName = 'CodexCcxPortable'
    try {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        $action = New-ScheduledTaskAction -Execute $ccxTargetBinary
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    } catch {
        Write-Warning "Auto-start registration failed; CCX still runs for this session: $($_.Exception.Message)"
    }
}

$smoke = $null
if (-not $SkipSmokeTest) {
    $smoke = & (Join-Path $repoRoot 'scripts\Invoke-SmokeTest.ps1') -HealthUri $healthUri -ProxyToken $ProxyToken
}

[pscustomobject]@{
    result = 'installed'
    codexConfig = $codexConfigPath
    auth = $authPath
    catalog = if ($ModelCatalogPath) { $catalogTargetPath } else { '' }
    catalogMode = $catalogMode
    ccxBinary = $ccxTargetBinary
    ccxConfig = Join-Path $ccxConfigDir 'config.json'
    health = [string]$health.status
    smokeTest = if ($smoke) { ($smoke | ConvertFrom-Json).status } else { 'skipped' }
    approvalPolicy = $ApprovalPolicy
    sandboxMode = $SandboxMode
} | ConvertTo-Json -Depth 4

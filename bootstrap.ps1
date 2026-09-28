[CmdletBinding()]
param(
    [switch]$RunInstaller,
    [switch]$InstallNginx,
    [switch]$SkipCodexInstall,
    [switch]$ConfigureNginxOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

function Update-CurrentPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machinePath;$userPath"
}

function Install-WingetPackage {
    param([string]$Id)
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget is required to install $Id. Install App Installer from the Microsoft Store, then retry."
    }
    & winget.exe install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget failed for $Id with exit code $LASTEXITCODE" }
    Update-CurrentPath
}

Update-CurrentPath
if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
    Install-WingetPackage 'Microsoft.PowerShell'
    Update-CurrentPath
}
if (-not (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
    throw 'PowerShell 7 was installed, but pwsh.exe is not in PATH. Open a new terminal and retry.'
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    Install-WingetPackage 'Git.Git'
}
if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    Install-WingetPackage 'OpenJS.NodeJS.LTS'
}

$pwshArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'scripts\setup-nginx.ps1'))
if ($ConfigureNginxOnly) { $pwshArgs += '-ConfigureOnly' }
if ($InstallNginx -or $ConfigureNginxOnly) {
    & pwsh.exe @pwshArgs
    if ($LASTEXITCODE -ne 0) { throw "Nginx setup failed with exit code $LASTEXITCODE" }
}

if ($RunInstaller) {
    $installerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repoRoot 'install.ps1'))
    if ($SkipCodexInstall) { $installerArgs += '-SkipCodexInstall' }
    & pwsh.exe @installerArgs
    if ($LASTEXITCODE -ne 0) { throw "install.ps1 failed with exit code $LASTEXITCODE" }
} else {
    [pscustomobject]@{
        result = 'power-shell-ready'
        pwsh = (Get-Command pwsh.exe).Source
        next = 'Run bootstrap.ps1 -RunInstaller to continue'
    } | ConvertTo-Json -Compress
}

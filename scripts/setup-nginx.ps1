[CmdletBinding()]
param(
    [string]$NginxRoot = (Join-Path $env:LOCALAPPDATA 'Programs\nginx'),
    [int]$Port = 8443,
    [string]$Version = '1.28.0',
    [switch]$ConfigureOnly,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Run this script with PowerShell 7: pwsh -NoProfile -File scripts/setup-nginx.ps1'
}

$confDir = Join-Path $NginxRoot 'conf'
$logsDir = Join-Path $NginxRoot 'logs'
$tempDir = Join-Path $NginxRoot 'temp'
$nginxExe = Join-Path $NginxRoot 'nginx.exe'
$confPath = Join-Path $confDir 'nginx.conf'
$healthUri = "https://127.0.0.1:$Port/nginx-health"

function Find-OpenSsl {
    $command = Get-Command openssl.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        'C:\Program Files\Git\usr\bin\openssl.exe',
        'C:\Program Files\Git\mingw64\bin\openssl.exe',
        'C:\Program Files\OpenSSL-Win64\bin\openssl.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw 'openssl.exe was not found. Install Git for Windows or OpenSSL, then retry.'
}

function Invoke-Nginx {
    param([string[]]$Arguments)
    $output = & $nginxExe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "nginx exited with $LASTEXITCODE : $($output -join ' ')"
    }
    return $output
}

New-Item -ItemType Directory -Force -Path $NginxRoot, $confDir, $logsDir, $tempDir | Out-Null

if (-not (Test-Path -LiteralPath $nginxExe)) {
    if ($ConfigureOnly) {
        throw "ConfigureOnly requires an existing nginx.exe at $nginxExe"
    }
    $zipUrl = "https://nginx.org/download/nginx-$Version.zip"
    $zipPath = Join-Path ([IO.Path]::GetTempPath()) "nginx-$Version.zip"
    $extractRoot = Join-Path ([IO.Path]::GetTempPath()) ("nginx-$Version-" + [Guid]::NewGuid().ToString('N'))
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -TimeoutSec 120
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    $source = if (Test-Path -LiteralPath (Join-Path $extractRoot "nginx-$Version\nginx.exe")) {
        Join-Path $extractRoot "nginx-$Version"
    } else {
        Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1 | ForEach-Object { $_.FullName }
    }
    if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'nginx.exe'))) {
        throw "Downloaded archive does not contain nginx.exe: $zipUrl"
    }
    Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $NginxRoot -Recurse -Force
    Remove-Item -LiteralPath $zipPath -Force
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}

$openSsl = Find-OpenSsl
$certPath = Join-Path $confDir 'cert.pem'
$keyPath = Join-Path $confDir 'cert.key'
$opensslConf = Join-Path $confDir 'openssl.cnf'
$opensslConfigText = @'
[req]
prompt = no
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = 127.0.0.1

[v3_req]
subjectAltName = IP:127.0.0.1,DNS:localhost
'@
[IO.File]::WriteAllText($opensslConf, $opensslConfigText, [Text.UTF8Encoding]::new($false))
if (-not (Test-Path -LiteralPath $certPath) -or -not (Test-Path -LiteralPath $keyPath)) {
    & $openSsl req -config $opensslConf -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 `
        -extensions v3_req `
        -keyout $keyPath -out $certPath
    if ($LASTEXITCODE -ne 0) { throw "openssl certificate generation failed with $LASTEXITCODE" }
}

$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\nginx.conf.template'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "nginx template not found: $templatePath"
}
if (Test-Path -LiteralPath $confPath) {
    Copy-Item -LiteralPath $confPath -Destination "$confPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
}
$posixRoot = $NginxRoot.Replace('\', '/')
$config = Get-Content -LiteralPath $templatePath -Raw
$config = $config.Replace('__NGINX_ROOT__', $posixRoot).Replace('__PORT__', [string]$Port)
[IO.File]::WriteAllText($confPath, $config, [Text.UTF8Encoding]::new($false))

Invoke-Nginx @('-t', '-p', $NginxRoot, '-c', $confPath) | Out-Null

$connection = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$started = $false
if (-not $connection) {
    if (-not $NoStart) {
        $startArguments = "-p `"$NginxRoot`" -c `"$confPath`""
        Start-Process -FilePath $nginxExe -ArgumentList $startArguments -WorkingDirectory $NginxRoot -WindowStyle Hidden
        $started = $true
    }
} else {
    $runningPath = (Get-Process -Id $connection.OwningProcess -ErrorAction Stop).Path
    if ($runningPath -ieq $nginxExe) {
        if (-not $NoStart) { Invoke-Nginx @('-s', 'reload', '-p', $NginxRoot, '-c', $confPath) | Out-Null }
    } else {
        throw "Port $Port is owned by another executable: $runningPath"
    }
}

if (-not $NoStart) {
    $deadline = (Get-Date).AddSeconds(20)
    do {
        try {
            $response = Invoke-WebRequest -Uri $healthUri -SkipCertificateCheck -TimeoutSec 3
            if ($response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'ok') { break }
        } catch { Start-Sleep -Seconds 1 }
    } while ((Get-Date) -lt $deadline)

    if (-not (Invoke-WebRequest -Uri $healthUri -SkipCertificateCheck -TimeoutSec 5).Content.Trim().Equals('ok')) {
        throw "Nginx health check failed: $healthUri"
    }
}

[pscustomobject]@{
    result = if ($NoStart) { 'configured' } elseif ($started) { 'started' } else { 'reloaded-or-running' }
    nginxRoot = $NginxRoot
    config = $confPath
    health = if ($NoStart) { 'not-checked' } else { $healthUri }
} | ConvertTo-Json -Compress

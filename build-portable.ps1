[CmdletBinding()]
param(
    [switch]$Private,
    [string]$SourceCcxConfigPath = "$env:APPDATA\ccx-desktop\.config\config.json",
    [string]$SourceCcxBinaryPath = 'C:\Program Files\CCX\CCX Desktop\ccx-go.exe',
    [string]$SourceCodexConfigPath = "$env:USERPROFILE\.codex\config.toml",
    [string]$SourceModelCatalogPath = "$env:USERPROFILE\.codex\ccx-model-catalog.json",
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$distDir = if ($OutputDirectory) { $OutputDirectory } else { Join-Path $repoRoot 'dist' }
$stage = Join-Path ([IO.Path]::GetTempPath()) ("codex-ccx-portable-" + [Guid]::NewGuid().ToString('N'))

function Copy-Tree {
    param([string]$From, [string]$To, [string[]]$ExcludeNames = @())
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Get-ChildItem -LiteralPath $From -Force |
        Where-Object { $ExcludeNames -notcontains $_.Name } |
        ForEach-Object {
            $target = Join-Path $To $_.Name
            if ($_.PSIsContainer) {
                Copy-Tree $_.FullName $target
            } else {
                Copy-Item -LiteralPath $_.FullName -Destination $target -Force
            }
        }
}

try {
    New-Item -ItemType Directory -Force -Path $distDir, $stage | Out-Null
    Copy-Tree -From $repoRoot -To $stage -ExcludeNames @('dist', '.git', 'payload')

    if ($Private) {
        foreach ($path in @($SourceCcxConfigPath, $SourceCcxBinaryPath, $SourceCodexConfigPath, $SourceModelCatalogPath)) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required private source not found: $path"
            }
        }

        $codexConfig = Get-Content -LiteralPath $SourceCodexConfigPath -Raw
        $tokenMatches = [regex]::Matches($codexConfig, '(?m)^\s*experimental_bearer_token\s*=\s*"([^"]+)"')
        if ($tokenMatches.Count -eq 0 -or -not $tokenMatches[0].Groups[1].Value) {
            throw "No experimental_bearer_token found in $SourceCodexConfigPath"
        }
        $proxyToken = $tokenMatches[0].Groups[1].Value

        $null = Get-Content -LiteralPath $SourceCcxConfigPath -Raw | ConvertFrom-Json
        $null = Get-Content -LiteralPath $SourceModelCatalogPath -Raw | ConvertFrom-Json
        $binaryHeader = [System.IO.File]::ReadAllBytes($SourceCcxBinaryPath)[0..1]
        if ($binaryHeader[0] -ne 0x4D -or $binaryHeader[1] -ne 0x5A) {
            throw "SourceCcxBinaryPath is not a Windows executable: $SourceCcxBinaryPath"
        }

        $privateDir = Join-Path $stage 'payload\private'
        New-Item -ItemType Directory -Force -Path $privateDir | Out-Null
        Copy-Item -LiteralPath $SourceCcxConfigPath -Destination (Join-Path $privateDir 'ccx-config.json') -Force
        Copy-Item -LiteralPath $SourceCcxBinaryPath -Destination (Join-Path $privateDir 'ccx-go.exe') -Force
        Copy-Item -LiteralPath $SourceModelCatalogPath -Destination (Join-Path $privateDir 'ccx-model-catalog.json') -Force
        [System.IO.File]::WriteAllText(
            (Join-Path $privateDir 'proxy-token.txt'),
            $proxyToken,
            [System.Text.UTF8Encoding]::new($false)
        )
        $warning = @(
            'PRIVATE MIGRATION BUNDLE',
            'This archive contains model provider API keys and a local proxy token.',
            'Do not publish it. Transfer only through an encrypted or trusted channel.'
        ) -join [Environment]::NewLine
        [System.IO.File]::WriteAllText((Join-Path $stage 'PRIVATE-WARNING.txt'), $warning, [System.Text.UTF8Encoding]::new($false))
    }

    $suffix = if ($Private) { 'private' } else { 'public' }
    $zipPath = Join-Path $distDir "codex-ccx-portable-$suffix.zip"
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256

    [pscustomobject]@{
        archive = $zipPath
        mode = $suffix
        sizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
        sha256 = $hash.Hash
        warning = if ($Private) { 'Contains secrets; do not publish' } else { 'No secrets' }
    } | ConvertTo-Json -Compress
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

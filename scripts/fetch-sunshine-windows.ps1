param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$pin = Get-Content (Join-Path $root 'Windows/engine.lock.json') -Raw | ConvertFrom-Json
$asset = $pin.$Architecture
$downloads = Join-Path $root '.build/downloads'
New-Item $downloads -ItemType Directory -Force | Out-Null
$archive = Join-Path $downloads $asset.asset
if (-not (Test-Path $archive)) {
    Invoke-WebRequest "https://github.com/LizardByte/Sunshine/releases/download/$($pin.version)/$($asset.asset)" -OutFile $archive
}
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) {
    throw 'Sunshine checksum mismatch. Refusing to use this download.'
}
$destination = Join-Path $root "Vendor/StreamingRuntime-Windows-$Architecture"
$staging = Join-Path $downloads ("sunshine-windows-" + [guid]::NewGuid())
try {
    Expand-Archive $archive -DestinationPath $staging
    $source = Join-Path $staging 'Sunshine'
    if (-not (Test-Path (Join-Path $source 'sunshine.exe')) -or -not (Test-Path (Join-Path $source 'assets'))) {
        throw 'The verified archive does not contain the expected runtime.'
    }
    # Only generated dependencies in this exact directory are replaced.
    if (Test-Path $destination) { Remove-Item $destination -Recurse -Force }
    New-Item $destination -ItemType Directory -Force | Out-Null
    Copy-Item (Join-Path $source 'sunshine.exe') $destination
    Get-ChildItem $source -File -Filter '*.dll' | Copy-Item -Destination $destination
    Copy-Item (Join-Path $source 'assets') $destination -Recurse
    # No service launcher, setup scripts, automatic driver installation, or separate app.
    Write-Host "Verified Windows $Architecture engine: $destination"
} finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
}

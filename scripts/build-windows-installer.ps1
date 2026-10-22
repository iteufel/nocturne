param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$Version = '1.0.0',
    [string]$SourceDirectory = '',
    [string]$Compiler = '',
    [string]$OutputName = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Build the Windows installer on Windows.' }
if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') { throw 'Use a numeric Windows version, such as 1.0.0.' }
$root = Split-Path $PSScriptRoot -Parent
if (-not $SourceDirectory) { $SourceDirectory = Join-Path $root ".build/WindowsRelease/win-$Architecture" }
if (-not (Test-Path (Join-Path $SourceDirectory 'Nocturne Server.exe'))) { throw 'Publish the complete Windows app before creating its installer.' }
$release = Join-Path $root '.build/WindowsRelease'
if (-not $Compiler) {
    $lock = Get-Content (Join-Path $root 'Windows/Installer/toolchain.lock.json') -Raw | ConvertFrom-Json
    $tools = Join-Path $root ".build/InnoSetup-$($lock.version)"
    $Compiler = Join-Path $tools 'ISCC.exe'
    if (-not (Test-Path $Compiler)) {
        $download = Join-Path $root ".build/innosetup-$($lock.version).exe"
        if (-not (Test-Path $download)) { Invoke-WebRequest $lock.url -OutFile $download }
        if ((Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.sha256) { throw 'Inno Setup checksum verification failed.' }
        $signature = Get-AuthenticodeSignature $download
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B.V.') { throw 'Inno Setup publisher verification failed.' }
        $process = Start-Process $download -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$tools`"") -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'The pinned Inno Setup compiler could not be installed.' }
    }
}
if (-not $OutputName) { $OutputName = "Nocturne-Windows-$Architecture-Setup" }
& $Compiler "/DSourceDir=$SourceDirectory" "/DOutputDir=$release" "/DArchitecture=$Architecture" "/DAppVersion=$Version" "/DOutputName=$OutputName" (Join-Path $root 'Windows/Installer/Nocturne.iss')
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed.' }
$installer = Join-Path $release "$OutputName.exe"
$hash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $installer -Leaf)" | Add-Content (Join-Path $release "SHA256SUMS-$Architecture.txt") -Encoding utf8NoBOM
Write-Host "Windows installer: $installer"

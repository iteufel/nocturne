param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [string]$Dotnet = 'dotnet',
    [string]$NativeDirectory = '',
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$sdk = & $Dotnet --version
if ($LASTEXITCODE -ne 0 -or [int]($sdk.Split('.')[0]) -lt 10) { throw 'Install the .NET 10 SDK to build the Windows server.' }
& (Join-Path $PSScriptRoot 'fetch-sunshine-windows.ps1') -Architecture $Architecture
if ($IsWindows -and -not $NativeDirectory) {
    & (Join-Path $PSScriptRoot 'build-windows-native.ps1') -Architecture $Architecture -SkipTests:$SkipTests
}
if (-not $NativeDirectory) { $NativeDirectory = Join-Path $root ".build/WindowsNative/$Architecture" }
foreach ($library in @('nocturne_host.dll', 'nocturne_remote.dll')) {
    if (-not (Test-Path (Join-Path $NativeDirectory $library))) { throw "Missing $library. Build on Windows, or pass -NativeDirectory with native libraries for $Architecture." }
}
if (-not $SkipTests) {
    & $Dotnet test (Join-Path $root 'Windows/Nocturne.Host.Tests/Nocturne.Host.Tests.csproj') -c Release -p:RestoreLockedMode=true --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Windows host tests failed.' }
    if ($IsWindows) {
        $env:NOCTURNE_WINDOWS_TEST_ARTIFACTS = Join-Path $root ".build/WindowsTests-$Architecture"
        & $Dotnet test (Join-Path $root 'Windows/Nocturne.Server.Tests/Nocturne.Server.Tests.csproj') -c Release -p:RestoreLockedMode=true "-p:NativeArchitecture=$Architecture" --nologo
        if ($LASTEXITCODE -ne 0) { throw 'Windows application startup tests failed.' }
        Remove-Item Env:NOCTURNE_WINDOWS_TEST_ARTIFACTS
    }
}
$release = Join-Path $root '.build/WindowsRelease'
$output = Join-Path $release "win-$Architecture"
if (Test-Path $output) { Remove-Item $output -Recurse -Force }
& $Dotnet publish (Join-Path $root 'Windows/Nocturne.Server/Nocturne.Server.csproj') -c Release -r "win-$Architecture" --self-contained true -p:RestoreLockedMode=true "-p:NativeArchitecture=$Architecture" -o $output --nologo
if ($LASTEXITCODE -ne 0) { throw 'Windows server publish failed.' }
Copy-Item (Join-Path $root "Vendor/StreamingRuntime-Windows-$Architecture") (Join-Path $output 'engine') -Recurse
Copy-Item (Join-Path $NativeDirectory '*.dll') $output -Force
foreach ($file in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) { Copy-Item (Join-Path $root $file) $output }
Copy-Item (Join-Path $root 'docs/WINDOWS.md') (Join-Path $output 'README.md')
Copy-Item (Join-Path $root 'Windows/engine.lock.json') $output
Copy-Item (Join-Path $PSScriptRoot 'configure-windows-firewall.ps1') $output
Copy-Item (Join-Path $PSScriptRoot 'configure-windows-display.ps1') $output
$notices = Join-Path $output 'licenses'
New-Item $notices -ItemType Directory -Force | Out-Null
$assets = Get-Content (Join-Path $root 'Windows/Nocturne.Server/obj/project.assets.json') -Raw | ConvertFrom-Json
$packageFolders = @($assets.packageFolders.PSObject.Properties.Name)
function Copy-PackageNotice([string]$RelativePath, [string]$Name) {
    foreach ($cache in $packageFolders) {
        $source = Join-Path $cache $RelativePath
        if (Test-Path $source) { Copy-Item $source (Join-Path $notices $Name); return }
    }
    throw "A dependency license is missing: $RelativePath"
}
[xml]$project = Get-Content (Join-Path $root 'Windows/Nocturne.Server/Nocturne.Server.csproj') -Raw
$runtimeVersion = $project.Project.PropertyGroup.RuntimeFrameworkVersion
Copy-PackageNotice 'bouncycastle.cryptography/2.7.0/LICENSE.md' 'BouncyCastle-LICENSE.md'
Copy-PackageNotice 'qrcoder/1.8.1/LICENSE.txt' 'QRCoder-LICENSE.txt'
Copy-PackageNotice "microsoft.netcore.app.runtime.win-$Architecture/$runtimeVersion/LICENSE.TXT" 'Dotnet-LICENSE.txt'
Copy-PackageNotice "microsoft.netcore.app.runtime.win-$Architecture/$runtimeVersion/THIRD-PARTY-NOTICES.TXT" 'Dotnet-THIRD-PARTY-NOTICES.txt'
Copy-PackageNotice "microsoft.windowsdesktop.app.runtime.win-$Architecture/$runtimeVersion/LICENSE" 'WPF-LICENSE.txt'
Copy-PackageNotice 'system.security.cryptography.protecteddata/10.0.13/THIRD-PARTY-NOTICES.TXT' 'ProtectedData-THIRD-PARTY-NOTICES.txt'
$archive = Join-Path $release "Nocturne-Server-Windows-$Architecture.zip"
if (Test-Path $archive) { Remove-Item $archive -Force }
Compress-Archive (Join-Path $output '*') $archive
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $(Split-Path $archive -Leaf)" | Set-Content (Join-Path $release "SHA256SUMS-$Architecture.txt") -Encoding utf8NoBOM
Write-Host "Windows server package: $archive"

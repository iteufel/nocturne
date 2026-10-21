param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64', [string]$Version = '1.0.0')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw 'Run installer verification on Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$release = Join-Path $root '.build/WindowsRelease'
$evidence = Join-Path $root ".build/WindowsTests-$Architecture/Installer"
New-Item $evidence -ItemType Directory -Force | Out-Null
$profile = Join-Path $env:LOCALAPPDATA 'Nocturne'
$registration = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{A85D3260-8436-48FD-9A64-128A33568A4D}_is1'
if ((Test-Path $profile) -or (Test-Path $registration)) { throw 'Installer smoke tests require a disposable Windows user without an existing Nocturne profile or installation.' }
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Nocturne Installer Test ' + [guid]::NewGuid())
$installed = Join-Path $testRoot 'Installed Nocturne'
$executable = Join-Path $installed 'Nocturne Server.exe'
function Invoke-Program([string]$File, [string[]]$Arguments) {
    $start = [System.Diagnostics.ProcessStartInfo]::new($File)
    $start.UseShellExecute = $false
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($start)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "$File exited with $($process.ExitCode)." }
    $process.Dispose()
}
$previous = "Nocturne-Windows-$Architecture-UpgradeFixture-Setup"
& (Join-Path $PSScriptRoot 'build-windows-installer.ps1') -Architecture $Architecture -Version '0.9.0' -OutputName $previous
$application = $null
try {
    Invoke-Program (Join-Path $release "$previous.exe") @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', "/DIR=$installed", '/TASKS=', "/LOG=$(Join-Path $evidence 'install.log')")
    if (-not (Test-Path $executable) -or -not (Test-Path (Join-Path $installed 'nocturne_host.dll')) -or -not (Test-Path (Join-Path $installed 'engine/sunshine.exe'))) { throw 'The installed application is incomplete.' }
    if ((Get-ItemProperty $registration).DisplayVersion -ne '0.9.0') { throw 'The initial version was not registered.' }
    New-Item $profile -ItemType Directory | Out-Null
    '{"screenSharing":false,"terminal":false,"files":false,"microphone":false}' | Set-Content (Join-Path $profile 'settings.json') -Encoding utf8NoBOM
    '{"appearance":"Dark","welcomeCompleted":true}' | Set-Content (Join-Path $profile 'preferences.json') -Encoding utf8NoBOM
    $key = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect($key, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [System.IO.File]::WriteAllBytes((Join-Path $profile 'workspace.key'), $protected)
    $before = (Get-FileHash (Join-Path $profile 'workspace.key')).Hash
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item $runKey -Force | Out-Null
    New-ItemProperty $runKey -Name 'Nocturne Server' -Value ('"' + $executable + '" --login') -Force | Out-Null
    $application = [System.Diagnostics.Process]::Start($executable)
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        if ($application.HasExited) { throw 'The installed app exited during startup.' }
        $application.Refresh()
        if ($application.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($application.MainWindowHandle -eq [IntPtr]::Zero) { throw 'The installed app did not open a native window.' }
    Invoke-Program (Join-Path $release "Nocturne-Windows-$Architecture-Setup.exe") @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', "/DIR=$installed", '/TASKS=', "/LOG=$(Join-Path $evidence 'upgrade.log')")
    if (-not $application.WaitForExit(10000)) { throw 'Upgrade did not gracefully stop the running app.' }
    if ((Get-ItemProperty $registration).DisplayVersion -ne $Version) { throw 'Upgrade did not replace the registered version.' }
    if ((Get-FileHash (Join-Path $profile 'workspace.key')).Hash -ne $before) { throw 'Upgrade changed the protected pairing key.' }
    if ((Get-ItemProperty $runKey).'Nocturne Server' -ne ('"' + $executable + '" --login')) { throw 'Upgrade lost login startup registration.' }
    $command = (Get-ItemProperty 'HKCU:\Software\Classes\nocturne\shell\open\command').'(default)'
    if (-not $command.Contains($executable)) { throw 'The pairing URL handler was not registered.' }
    Invoke-Program (Join-Path $installed 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$(Join-Path $evidence 'uninstall.log')")
    if ((Test-Path $executable) -or (Test-Path $registration)) { throw 'Uninstall left the app or its uninstall registration behind.' }
    if ((Get-FileHash (Join-Path $profile 'workspace.key')).Hash -ne $before -or -not (Test-Path (Join-Path $profile 'preferences.json'))) { throw 'Uninstall removed user data.' }
    if (Get-ItemProperty $runKey -Name 'Nocturne Server' -ErrorAction SilentlyContinue) { throw 'Uninstall left login startup pointing to a removed executable.' }
    'PASS: per-user install; native app startup; upgrade from 0.9.0 with a running app; pairing-key and startup preservation; URL handler; uninstall retaining user data.' | Set-Content (Join-Path $evidence 'result.txt')
} finally {
    if ($application -and -not $application.HasExited) { $application.Kill(); $application.WaitForExit() }
    if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force }
    if (Test-Path $profile) { Remove-Item $profile -Recurse -Force }
    Remove-Item (Join-Path $release "$previous.exe") -ErrorAction SilentlyContinue
    $checksums = Join-Path $release "SHA256SUMS-$Architecture.txt"
    @(Get-Content $checksums | Where-Object { -not $_.Contains($previous) }) | Set-Content $checksums -Encoding utf8NoBOM
}

#requires -RunAsAdministrator
param([Parameter(Mandatory = $true)][string]$UserSid)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This setup helper requires Windows.' }
$user = [System.Security.Principal.SecurityIdentifier]$UserSid
if (-not $user.IsAccountSid()) { throw 'Choose a Windows user account.' }
$registry = 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver'
if (-not (Test-Path $registry)) { throw 'Install the signed virtual display driver with Virtual Driver Control first, then run this helper again.' }
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Nocturne'
$destination = Join-Path $root 'VirtualDisplay'
foreach ($folder in @($root, $destination)) {
    if ((Test-Path $folder) -and ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The Nocturne configuration folder cannot be a link or junction.' }
    if (Test-Path $folder) {
        $owner = (Get-Acl -LiteralPath $folder).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'The shared Nocturne configuration folder has an unexpected owner. Have an administrator review it before running setup.' }
    } else { New-Item -ItemType Directory -Path $folder | Out-Null }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $administrators = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $acl.SetOwner($administrators)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    $readers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($readers, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $folder -AclObject $acl
}
$properties = Get-ItemProperty -LiteralPath $registry
$previous = if ($properties.PSObject.Properties['VDDPATH']) { [string]$properties.VDDPATH } else { 'C:\VirtualDisplayDriver' }
$source = Join-Path $previous 'vdd_settings.xml'
$target = Join-Path $destination 'vdd_settings.xml'
$document = New-Object System.Xml.XmlDocument
$document.XmlResolver = $null
if (Test-Path $source) {
    $readerSettings = New-Object System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $readerSettings.MaxCharactersInDocument = 1048576
    $reader = [System.Xml.XmlReader]::Create($source, $readerSettings)
    try { $document.Load($reader) } finally { $reader.Dispose() }
} else {
    $document.LoadXml('<vdd_settings><monitors><count>1</count></monitors><gpu><friendlyname>default</friendlyname></gpu><resolutions><resolution><width>1920</width><height>1080</height><refresh_rate>60</refresh_rate></resolution></resolutions></vdd_settings>')
}
if ($document.DocumentElement.Name -ne 'vdd_settings') { throw 'The virtual display configuration is invalid.' }
$temporary = Join-Path $destination ([Guid]::NewGuid().ToString() + '.tmp')
$document.Save($temporary)
if (Test-Path $target) { Remove-Item -LiteralPath $target -Force }
Move-Item -LiteralPath $temporary -Destination $target
$backup = Join-Path $destination 'previous-driver-path.txt'
if (-not (Test-Path $backup)) {
    [IO.File]::WriteAllText($backup, $previous)
    $backupAcl = New-Object System.Security.AccessControl.FileSecurity
    $backupAcl.SetAccessRuleProtection($true, $false)
    $backupAcl.SetOwner($administrators)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $backupAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    }
    $backupAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($readers, 'Read', 'Allow')))
    Set-Acl -LiteralPath $backup -AclObject $backupAcl
}
foreach ($name in @('monitor_profile.xml', 'user_edid.bin')) {
    $existing = Join-Path $previous $name
    if ((Test-Path $existing) -and $previous -ne $destination) {
        if ((Get-Item -LiteralPath $existing).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Driver configuration assets cannot be links.' }
        $temporary = Join-Path $destination ([Guid]::NewGuid().ToString() + '.tmp')
        Copy-Item -LiteralPath $existing -Destination $temporary
        $targetAsset = Join-Path $destination $name
        if (Test-Path $targetAsset) { Remove-Item -LiteralPath $targetAsset -Force }
        Move-Item -LiteralPath $temporary -Destination $targetAsset
    }
}
$acl = Get-Acl -LiteralPath $destination
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $destination -AclObject $acl
Set-ItemProperty -LiteralPath $registry -Name VDDPATH -Value $destination -Type String
Write-Host 'Nocturne can now add virtual monitor resolutions. Restart the virtual display driver or the PC, then enable Headless virtual monitor in Nocturne.'

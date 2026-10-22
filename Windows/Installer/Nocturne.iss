#ifndef SourceDir
  #error SourceDir must point to the published application.
#endif
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef Architecture
  #define Architecture "x64"
#endif
#ifndef OutputName
  #define OutputName "Nocturne-Windows-" + Architecture + "-Setup"
#endif
[Setup]
AppId={{A85D3260-8436-48FD-9A64-128A33568A4D}
AppName=Nocturne
AppVersion={#AppVersion}
AppPublisher=Nocturne
AppPublisherURL=https://github.com/iteufel/nocturne
AppSupportURL=https://github.com/iteufel/nocturne/issues
DefaultDirName={localappdata}\Programs\Nocturne
DefaultGroupName=Nocturne
PrivilegesRequired=lowest
MinVersion=10.0.19041
#if Architecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
#endif
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
SetupIconFile=..\Nocturne.Server\app.ico
UninstallDisplayIcon={app}\Nocturne Server.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=no
RestartApplications=no
ChangesAssociations=yes
LicenseFile={#SourceDir}\LICENSE
[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Nocturne"; Filename: "{app}\Nocturne Server.exe"
Name: "{autodesktop}\Nocturne"; Filename: "{app}\Nocturne Server.exe"; Tasks: desktopicon
[Registry]
Root: HKCU; Subkey: "Software\Classes\nocturne"; ValueType: string; ValueData: "URL:Nocturne pairing"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\nocturne"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\nocturne\DefaultIcon"; ValueType: string; ValueData: "{app}\Nocturne Server.exe,0"
Root: HKCU; Subkey: "Software\Classes\nocturne\shell\open\command"; ValueType: string; ValueData: """{app}\Nocturne Server.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Nocturne Server"; ValueData: """{app}\Nocturne Server.exe"" --login"; Check: LoginWasEnabled
[Run]
Filename: "{app}\Nocturne Server.exe"; Description: "Open Nocturne"; Flags: nowait postinstall skipifsilent
[Code]
const
  RunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';

function LoginWasEnabled: Boolean;
var Value: String;
begin
  Result := RegQueryStringValue(HKCU, RunKey, 'Nocturne Server', Value) and
    (Pos('nocturne server.exe', Lowercase(Value)) > 0) and (Pos('--login', Value) > 0);
end;

function StopNocturne: Boolean;
var Code: Integer; Executable: String;
begin
  Executable := ExpandConstant('{app}\Nocturne Server.exe');
  Result := True;
  if FileExists(Executable) then
    Result := Exec(Executable, '--shutdown', ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not StopNocturne then
    Result := 'Close Nocturne from its tray menu, then retry the installation.';
end;

function InitializeUninstall: Boolean;
begin
  Result := StopNocturne;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var Value: String;
begin
  if CurUninstallStep = usUninstall then begin
    if RegQueryStringValue(HKCU, RunKey, 'Nocturne Server', Value) and
       (Pos(Lowercase(ExpandConstant('{app}\Nocturne Server.exe')), Lowercase(Value)) > 0) then
      RegDeleteValue(HKCU, RunKey, 'Nocturne Server');
  end;
end;

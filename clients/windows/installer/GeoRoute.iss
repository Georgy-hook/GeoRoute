#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef PackageRoot
  #error PackageRoot is required
#endif
#ifndef OutputRoot
  #error OutputRoot is required
#endif

[Setup]
AppId={{78F280B6-67C0-45B9-8447-AC48B072AA2E}
AppName=GeoRoute
AppVersion={#AppVersion}
AppPublisher=GeoRoute contributors
AppPublisherURL=https://github.com/Georgy-hook/GeoRoute
AppSupportURL=https://github.com/Georgy-hook/GeoRoute/issues
AppUpdatesURL=https://github.com/Georgy-hook/GeoRoute/releases/latest
DefaultDirName={localappdata}\Programs\GeoRoute
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
WizardSizePercent=110
SetupIconFile={#PackageRoot}\_service\assets\app.ico
UninstallDisplayIcon={app}\_service\assets\app.ico
OutputDir={#OutputRoot}
OutputBaseFilename=GeoRoute-Setup-{#AppVersion}-x64
Compression=lzma2
SolidCompression=yes
AppMutex=Local\GeoRoute.Setup.Application
SetupMutex=Local\GeoRoute.Setup.Installer
CloseApplications=no
RestartApplications=no
Uninstallable=yes
InfoBeforeFile=install-info.ru.txt

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Ярлыки:"

[Files]
; Only the already verified portable payload is packaged, never the developer checkout.
Source: "{#PackageRoot}\*"; DestDir: "{app}"; Excludes: "_service\profiles.json,_service\connection-routes.json,_service\profiles\*"; Flags: ignoreversion recursesubdirs
; Mutable profile seeds are installed once. Updates and uninstall preserve user choices.
Source: "{#PackageRoot}\_service\profiles.json"; DestDir: "{app}\_service"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#PackageRoot}\_service\connection-routes.json"; DestDir: "{app}\_service"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#PackageRoot}\_service\profiles\*"; DestDir: "{app}\_service\profiles"; Flags: onlyifdoesntexist uninsneveruninstall recursesubdirs

[Icons]
Name: "{userprograms}\GeoRoute"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\_service\NextDNS-GUI.ps1"""; WorkingDir: "{app}\_service"; IconFilename: "{app}\_service\assets\app.ico"; Comment: "ChatGPT и Gemini — подключение и проверка серверов"; AppUserModelID: "GeoRoute.Desktop"
Name: "{userdesktop}\GeoRoute"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\_service\NextDNS-GUI.ps1"""; WorkingDir: "{app}\_service"; IconFilename: "{app}\_service\assets\app.ico"; Tasks: desktopicon; AppUserModelID: "GeoRoute.Desktop"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{app}\_service\NextDNS-GUI.ps1"""; WorkingDir: "{app}\_service"; Description: "Открыть GeoRoute"; Flags: postinstall nowait skipifsilent

[Code]
function InitializeUninstall(): Boolean;
var
  Hosts: AnsiString;
begin
  Result := True;
  { Never leave an enabled hosts route behind after removing its controls. }
  if not LoadStringFromFile(ExpandConstant('{sys}\drivers\etc\hosts'), Hosts) then
  begin
    MsgBox('Не удалось проверить подключение. Откройте GeoRoute, выключите его и повторите удаление.', mbError, MB_OK);
    Result := False;
  end
  else if Pos('# BEGIN CHATGPT-US-WINDOWS', String(Hosts)) > 0 then
  begin
    MsgBox('Сначала откройте GeoRoute и нажмите «Выключить». Затем выберите «Выход» в трее и повторите удаление. Это нужно, чтобы подключение не осталось включённым без приложения.', mbInformation, MB_OK);
    Result := False;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Current, OwnCommand: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    OwnCommand := '"' + ExpandConstant('{sys}\cmd.exe') + '" /d /s /c ""' + ExpandConstant('{app}\GeoRoute.cmd') + '" -Tray"';
    if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'NextDNS Connection Manager', Current) then
      if CompareText(Current, OwnCommand) = 0 then
        RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'NextDNS Connection Manager');
  end;
end;

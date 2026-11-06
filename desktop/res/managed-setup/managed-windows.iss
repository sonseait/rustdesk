; Build after package-managed-windows.py has staged the complete release.
#ifndef BundleDir
  #error BundleDir must point to the staged Flutter Windows release
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
[Setup]
AppId={{A6297C87-57F4-4E8D-8729-06DDABDC1F99}
AppName=RustDesk Managed Host
AppVersion=1.4.9
DefaultDirName={autopf}\RustDesk
CreateAppDir=no
Uninstallable=no
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
LicenseFile={#BundleDir}\usbmmidd_v2\License.txt
InfoBeforeFile=SETUP.txt
SetupIconFile=..\..\flutter\windows\runner\resources\app_icon.ico
OutputDir={#OutputDir}
OutputBaseFilename=rustdesk-managed-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableDirPage=yes
DisableProgramGroupPage=yes
CloseApplications=no

[Files]
Source: "{#BundleDir}\*"; DestDir: "{tmp}\managed-host"; Flags: recursesubdirs createallsubdirs dontcopy

[Code]
function RunHidden(const FileName, Args, WorkDir: String): String;
var
  Code: Integer;
begin
  Result := '';
  Log('Running: ' + FileName + ' ' + Args);
  if not Exec(FileName, Args, WorkDir, SW_HIDE, ewWaitUntilTerminated, Code) then
    Result := 'Could not start ' + ExtractFileName(FileName)
  else if Code <> 0 then
    Result := ExtractFileName(FileName) + ' failed (exit code ' + IntToStr(Code) + ').';
  if Result <> '' then Log(Result);
end;

function InstallHost(): String;
var
  WMI, Services, Devices, Service: Variant;
  Stage, AppExe, DriverDir, MonitorKey, ServicePath: String;
  StartMode: Cardinal;
  Attempt: Integer;
  ExistingDriver: Boolean;
begin
  Result := '';
  Stage := ExpandConstant('{tmp}\managed-host');
  AppExe := ExpandConstant('{autopf}\RustDesk\rustdesk.exe');
  DriverDir := ExpandConstant('{autopf}\RustDesk\usbmmidd_v2');
  MonitorKey := 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\usbmmIdd\Parameters\Monitors';
  try
    WMI := CreateOleObject('WbemScripting.SWbemLocator');
    WMI := WMI.ConnectServer('.', 'root\cimv2');
    Devices := WMI.ExecQuery('SELECT DeviceID FROM Win32_PnPEntity WHERE DeviceID LIKE ''ROOT\\USBMMIDD\\%''');
    ExistingDriver := Devices.Count > 0;

    WizardForm.StatusLabel.Caption := 'Installing RustDesk and its automatic service…';
    Result := RunHidden(Stage + '\rustdesk.exe', '--silent-install', Stage);
    if Result <> '' then Exit;
    if not FileExists(AppExe) then begin
      Result := 'Installed RustDesk executable was not found.';
      Exit;
    end;
    if not RegQueryDWordValue(HKLM64, 'SYSTEM\CurrentControlSet\Services\RustDesk', 'Start', StartMode) or (StartMode <> 2) then begin
      Result := 'RustDesk automatic service was not installed.';
      Exit;
    end;
    if not RegQueryStringValue(HKLM64, 'SYSTEM\CurrentControlSet\Services\RustDesk', 'ImagePath', ServicePath) or
        (Pos(Lowercase(AppExe), Lowercase(ServicePath)) = 0) then begin
      Result := 'RustDesk service points to an unexpected executable.';
      Exit;
    end;

    WizardForm.StatusLabel.Caption := 'Installing Amyuni virtual display driver…';
    if not ExistingDriver then begin
      { Windows validates the unchanged INF/catalog during device installation. }
      Result := RunHidden(DriverDir + '\deviceinstaller64.exe', 'install usbmmidd.inf usbmmidd', DriverDir);
      if Result <> '' then Exit;
    end;
    if not RegKeyExists(HKLM64, MonitorKey) then begin
      Result := 'Driver settings are unavailable. Keep RDP access; a reboot may be required.';
      Exit;
    end;
    if not RegWriteStringValue(HKLM64, MonitorKey, '', '2560,1440') then begin
      Result := 'Could not configure the virtual display resolution.';
      Exit;
    end;
    { enableidd 1 adds a monitor each time; do not duplicate it on upgrades. }
    if not ExistingDriver then begin
      Result := RunHidden(DriverDir + '\deviceinstaller64.exe', 'enableidd 1', DriverDir);
      if Result <> '' then Exit;
    end;

    WizardForm.StatusLabel.Caption := 'Checking RustDesk service…';
    Services := WMI.ExecQuery('SELECT State FROM Win32_Service WHERE Name=''RustDesk''');
    if Services.Count <> 1 then begin
      Result := 'RustDesk service was not found.';
      Exit;
    end;
    Service := Services.ItemIndex(0);
    if Service.State <> 'Running' then begin
      Result := RunHidden(ExpandConstant('{sys}\sc.exe'), 'start RustDesk', '');
      if Result <> '' then Exit;
    end;
    for Attempt := 1 to 30 do begin
      Services := WMI.ExecQuery('SELECT State FROM Win32_Service WHERE Name=''RustDesk''');
      if Services.Count = 1 then begin
        Service := Services.ItemIndex(0);
        if Service.State = 'Running' then Exit;
      end;
      Sleep(500);
    end;
    Result := 'RustDesk service is not running. Check the service log before removing RDP access.';
  except
    Result := 'Host setup failed: ' + GetExceptionMessage;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  ExtractTemporaryFiles('*');
  Result := InstallHost();
  if Result <> '' then
    Result := Result + #13#10 + 'Installation may be partial. Keep RDP access. No automatic rollback or reboot was performed.';
end;

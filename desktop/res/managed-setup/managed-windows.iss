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
function InstallHost(): String;
var
  Code: Integer;
  Args: String;
begin
  Result := '';
  Args := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\managed-host\Setup.ps1') + '" -LicenseAccepted';
  if not Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      Args, ExpandConstant('{tmp}\managed-host'), SW_SHOW, ewWaitUntilTerminated, Code) then
    Result := 'Could not launch Windows host setup.'
  else if Code <> 0 then
    Result := 'Host setup failed (exit code ' + IntToStr(Code) + '). Installation may be partial. Keep your RDP fallback, inspect the setup error, and retry. No automatic rollback or reboot was performed.';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  ExtractTemporaryFiles('*');
  Result := InstallHost();
end;

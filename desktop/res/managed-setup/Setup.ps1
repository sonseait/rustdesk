# Run from the extracted release bundle. Never bypass UAC or driver signing.
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('1920,1080', '2560,1440', '3840,2160')][string]$Resolution = '2560,1440',
    [switch]$LicenseAccepted
)
$ErrorActionPreference = 'Stop'
if (![Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or [Environment]::OSVersion.Version.Build -lt 19041) {
    throw 'Managed host setup requires Windows x64, build 19041 or later.'
}
$sourceExe = Join-Path $PSScriptRoot 'rustdesk.exe'
$driver = Join-Path $PSScriptRoot 'usbmmidd_v2'
foreach ($file in @($sourceExe, "$driver\deviceinstaller64.exe", "$driver\usbmmIdd.inf", "$driver\usbmmidd.cat", "$driver\License.txt")) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing release file: $file" }
}
Write-Host 'Virtual display: Amyuni Technologies Inc. See usbmmidd_v2\License.txt.'
Write-Host 'Its license includes possible advertising pages. Windows/RustDesk authentication is unchanged.'
if (!$LicenseAccepted -and (Read-Host 'Type INSTALL to accept the included license and install the host service and driver') -cne 'INSTALL') {
    throw 'Installation cancelled.'
}
# Verify the driver catalog with Windows trust validation before installing it.
$signature = Get-AuthenticodeSignature -LiteralPath "$driver\usbmmidd.cat"
if ($signature.Status -ne 'Valid') { throw "Driver catalog signature is not trusted: $($signature.Status)" }
$install = Start-Process -FilePath $sourceExe -ArgumentList '--silent-install' -PassThru -Wait
if ($install.ExitCode -ne 0) { throw "Application installation failed: $($install.ExitCode)" }
$installedExe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
if (!(Test-Path -LiteralPath $installedExe)) { throw 'Installed RustDesk executable not found.' }
$service = Get-CimInstance Win32_Service -Filter "Name='RustDesk'"
if (!$service -or $service.PathName -notlike "*${installedExe}*" -or $service.StartMode -ne 'Auto') {
    throw 'RustDesk automatic service installation could not be verified.'
}
$installedDriver = Join-Path (Split-Path $installedExe) 'usbmmidd_v2'
if (!(Test-Path -LiteralPath "$installedDriver\deviceinstaller64.exe")) { throw 'Installed driver bundle not found.' }
$existing = Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -like 'ROOT\USBMMIDD\*' }
if (!$existing) {
    Push-Location $installedDriver
    try {
        & .\deviceinstaller64.exe install usbmmidd.inf usbmmidd
        if ($LASTEXITCODE -ne 0) { throw "Driver installation failed: $LASTEXITCODE" }
    } finally { Pop-Location }
}
$monitorKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\WUDF\Services\usbmmIdd\Parameters\Monitors'
if (!(Test-Path $monitorKey)) { throw 'Virtual display driver settings were not created. A reboot may be required.' }
Set-Item -LiteralPath $monitorKey -Value $Resolution
# enableidd 1 adds a monitor on every call, so do not add again on rerun.
if (!$existing) {
    Push-Location $installedDriver
    try {
        & .\deviceinstaller64.exe enableidd 1
        if ($LASTEXITCODE -ne 0) { throw "Virtual monitor activation failed: $LASTEXITCODE" }
    } finally { Pop-Location }
} else {
    Write-Host 'Existing Amyuni device retained; no additional virtual monitor was added.'
}
Start-Service -Name RustDesk
$service = Get-Service -Name RustDesk
if ($service.Status -ne 'Running') { throw 'RustDesk service is not running.' }
Write-Host "Service running. Virtual display default: $Resolution. Existing active displays may retain their saved mode."
Write-Host 'Verify the virtual monitor in Display Settings; then test lock screen, sign-out and reboot from another machine.'
Write-Host 'Do not remove your RDP fallback until managed enrollment and remote authentication work in the service account.'

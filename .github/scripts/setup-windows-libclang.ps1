$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$toolsRoot = $env:RUNNER_TOOL_CACHE
if (!$toolsRoot) {
    $toolsRoot = Join-Path $env:RUNNER_TEMP 'tools'
}
$llvmRoot = Join-Path $toolsRoot 'llvm/20.1.8/x64'
$candidates = @(
    $env:LIBCLANG_PATH
    (Join-Path $llvmRoot 'bin')
    (Join-Path $env:ProgramFiles 'LLVM/bin')
)
if ($env:VS_INSTALL_ROOT) {
    $candidates += Join-Path $env:VS_INSTALL_ROOT 'VC/Tools/Llvm/x64/bin'
}
$clang = Get-Command clang.exe -ErrorAction SilentlyContinue
if ($clang) {
    $candidates += Split-Path $clang.Source -Parent
}

# Never load/unload LLVM in PowerShell: its native shutdown handlers can crash
# the host process. Check the PE architecture here; bindgen loads the DLL later.
function Test-X64Dll($path) {
    $reader = $null
    try {
        $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($path))
        if ($reader.BaseStream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) {
            return $false
        }
        $reader.BaseStream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -lt 64 -or $peOffset -gt ($reader.BaseStream.Length - 24)) {
            return $false
        }
        $reader.BaseStream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) {
            return $false
        }
        $reader.BaseStream.Position = $peOffset + 22
        return ($reader.ReadUInt16() -band 0x2000) -ne 0
    } catch {
        Write-Host "Cannot inspect ${path}: $($_.Exception.Message)"
        return $false
    } finally {
        if ($reader) {
            $reader.Dispose()
        }
    }
}

function Find-LibClang($directories) {
    foreach ($directory in ($directories | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($name in @('libclang.dll', 'clang.dll')) {
            $dll = Join-Path $directory $name
            if (!(Test-Path $dll -PathType Leaf)) {
                continue
            }
            if (Test-X64Dll $dll) {
                return $directory
            }
            Write-Host "Skipping ${dll}: not an x64 Windows DLL."
        }
    }
}

$libclang = Find-LibClang $candidates
if (!$libclang) {
    $archive = Join-Path $env:RUNNER_TEMP 'llvm-20.1.8-windows-x64.tar.xz'
    try {
        Write-Host 'Installing portable LLVM 20.1.8 x64 into the runner tool cache.'
        Invoke-WebRequest -Uri 'https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.8/clang%2Bllvm-20.1.8-x86_64-pc-windows-msvc.tar.xz' -OutFile $archive
        $expectedHash = 'f229769f11d6a6edc8ada599c0cda964b7dee6ab1a08c6cf9dd7f513e85b107f'
        if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'The downloaded LLVM archive failed SHA-256 verification.'
        }
        New-Item -ItemType Directory -Force $llvmRoot | Out-Null
        $tar = Join-Path $env:SystemRoot 'System32/tar.exe'
        & $tar -xf $archive -C $llvmRoot --strip-components=1
    } finally {
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
    }
    $libclang = Find-LibClang @((Join-Path $llvmRoot 'bin'))
}
if (!$libclang) {
    throw 'An x64 Windows libclang.dll could not be found after LLVM setup.'
}

Write-Host "Using libclang from $libclang"
"LIBCLANG_PATH=$libclang" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
$libclang | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append

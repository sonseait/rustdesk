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

function Find-LibClang($directories) {
    foreach ($directory in ($directories | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($name in @('libclang.dll', 'clang.dll')) {
            $dll = Join-Path $directory $name
            if (!(Test-Path $dll -PathType Leaf)) {
                continue
            }
            $handle = [IntPtr]::Zero
            try {
                $handle = [System.Runtime.InteropServices.NativeLibrary]::Load($dll)
                [System.Runtime.InteropServices.NativeLibrary]::GetExport($handle, 'clang_getClangVersion') | Out-Null
                return $directory
            } catch {
                Write-Host "Cannot load ${dll}: $($_.Exception.Message)"
            } finally {
                if ($handle -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.NativeLibrary]::Free($handle)
                }
            }
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
    throw 'A loadable x64 libclang.dll could not be found after LLVM setup.'
}

Write-Host "Using libclang from $libclang"
"LIBCLANG_PATH=$libclang" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
$libclang | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append

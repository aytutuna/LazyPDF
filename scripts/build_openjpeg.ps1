# OpenJPEG 2.5.4 (tag v2.5.4, uclouvain/openjpeg commit bbbe3a0), sources in windows/native/openjpeg.
<#
Builds openjp2.dll from the vendored OpenJPEG sources with MSVC, one per architecture, into
windows/native/bin/<arch>/. An architecture whose DLL is newer than every source is skipped.

  pwsh scripts/build_openjpeg.ps1 [-Arch x64,arm64]
#>
param(
    [ValidateSet('x64', 'arm64')] [string[]] $Arch = @('x64', 'arm64')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$native = Join-Path $root 'windows\native'
$sources = Join-Path $native 'openjpeg'

$vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\Installer\vswhere.exe'

# The first install that has the C++ tools for the target; a plain -latest can be one without the ARM64 ones.
function Find-VcVars([string] $arch) {
    $component = if ($arch -eq 'arm64') { 'Microsoft.VisualStudio.Component.VC.Tools.ARM64' } else { 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' }
    $install = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires $component -property installationPath } else { $null }
    if (-not $install) { $install = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio\18\BuildTools' }
    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvarsall.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvarsall.bat is not in $install" }
    $vcvars
}

$newest = (Get-ChildItem $sources -File | Measure-Object LastWriteTime -Maximum).Maximum
$alloc = Join-Path $native 'openjpeg_alloc.c'
foreach ($f in @((Get-Item $PSCommandPath), (Get-Item $alloc))) {
    if ($f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime }
}

foreach ($a in $Arch) {
    $bin = Join-Path $native "bin\$a"
    $obj = Join-Path $native "obj\$a"
    $dll = Join-Path $bin 'openjp2.dll'
    if ((Test-Path $dll) -and (Get-Item $dll).LastWriteTime -gt $newest) {
        Write-Host "$dll is up to date"
        continue
    }
    New-Item -ItemType Directory -Path $bin, $obj -Force | Out-Null
    $vcvars = Find-VcVars $a
    $target = if ($a -eq 'x64') { 'x64' } else { 'x64_arm64' }
    # Our budgeted allocator stands in for the upstream opj_malloc.c.
    $files = (@(Get-ChildItem $sources -Filter *.c | Where-Object Name -ne 'opj_malloc.c' | ForEach-Object FullName) + $alloc | ForEach-Object { "`"$_`"" }) -join ' '
    $batch = Join-Path $obj 'build.cmd'
    Set-Content $batch -Encoding ascii @(
        '@echo off',
        "call `"$vcvars`" $target >nul || exit /b 1",
        "cd /d `"$obj`"",
        "cl /nologo /O2 /MT /GS /guard:cf /W3 /DOPJ_EXPORTS /DMUTEX_win32 /DNDEBUG /D_CRT_SECURE_NO_WARNINGS /I`"$sources`" /LD $files /Fe`"$dll`" /link /DYNAMICBASE /NXCOMPAT /guard:cf")
    & cmd /c $batch | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "openjp2 $a failed with exit code $LASTEXITCODE" }
    Write-Host "wrote $dll"
}

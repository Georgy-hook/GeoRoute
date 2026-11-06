#Requires -Version 5.1
[CmdletBinding()]
param(
 [string]$PythonExe='python.exe',
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='0.4.2',
 [string]$CompilerPath
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(-not $CompilerPath){
 $candidates=@((Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'))
 $CompilerPath=$candidates|Where-Object {Test-Path -LiteralPath $_}|Select-Object -First 1
}
if(-not $CompilerPath -or -not(Test-Path -LiteralPath $CompilerPath)){throw 'Install Inno Setup 6.7+ or specify -CompilerPath.'}
$output=Join-Path $PSScriptRoot 'dist'
$archive=Join-Path $output ('GeoRoute-Windows-x64-'+$Version+'.zip')
if(-not(Test-Path -LiteralPath $archive)){throw 'Build the portable ZIP first with the same Version.'}
$expected=(Get-Content -LiteralPath ($archive+'.sha256') -Raw).Split(' ')[0]
if((Get-FileHash -LiteralPath $archive).Hash -ine $expected){throw 'Portable ZIP hash mismatch.'}
& $PythonExe -I (Join-Path $PSScriptRoot 'tests\verify_package.py') $archive
if($LASTEXITCODE -ne 0){throw 'Portable package verification failed.'}
$buildRoot=Join-Path $PSScriptRoot '.build'
$stage=[IO.Path]::GetFullPath((Join-Path $buildRoot ('installer-'+[guid]::NewGuid().ToString('N'))))
try {
 [IO.Compression.ZipFile]::ExtractToDirectory($archive,$stage)
 & $CompilerPath '/Qp' ('/DAppVersion='+$Version) ('/DPackageRoot='+(Join-Path $stage 'GeoRoute')) ('/DOutputRoot='+$output) (Join-Path $PSScriptRoot 'installer\GeoRoute.iss')
 if($LASTEXITCODE -ne 0){throw 'Inno Setup compilation failed.'}
 $setup=Join-Path $output ('GeoRoute-Setup-'+$Version+'-x64.exe')
 $hash=(Get-FileHash -LiteralPath $setup).Hash.ToLowerInvariant()
 [IO.File]::WriteAllText(($setup+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($setup)+"`n"),[Text.Encoding]::ASCII)
 Write-Output ('Built '+$setup+' from verified portable payload '+$expected)
} finally {
 $resolved=[IO.Path]::GetFullPath($stage)
 if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($buildRoot)+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^installer-[a-f0-9]{32}$'){throw 'Unexpected installer staging path.'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

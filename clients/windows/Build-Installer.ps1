#Requires -Version 5.1
[CmdletBinding()]
param(
 [string]$PythonExe='python.exe',
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version='0.4.3',
 [string]$ArchivePath,
 [string]$OutputDirectory,
 [string]$WixBin
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(-not $WixBin){
 if($env:WIX){$WixBin=Join-Path $env:WIX 'bin'}else{$WixBin=Join-Path ${env:ProgramFiles(x86)} 'WiX Toolset v3.14\bin'}
}
if(-not(Test-Path -LiteralPath (Join-Path $WixBin 'candle.exe'))){throw 'Install WiX Toolset 3.14.1 or specify -WixBin.'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path $PSScriptRoot 'dist'}
$output=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $ArchivePath){$ArchivePath=Join-Path $PSScriptRoot ('dist\GeoRoute-Windows-x64-'+$Version+'.zip')}
$archive=[IO.Path]::GetFullPath($ArchivePath)
$expected=(Get-Content -LiteralPath ($archive+'.sha256') -Raw).Split(' ')[0]
if((Get-FileHash -LiteralPath $archive).Hash -ine $expected){throw 'Portable ZIP hash mismatch.'}
& $PythonExe -I (Join-Path $PSScriptRoot 'tests\verify_package.py') $archive
if($LASTEXITCODE -ne 0){throw 'Portable package verification failed.'}
$buildRoot=Join-Path $PSScriptRoot '.build'
$stage=[IO.Path]::GetFullPath((Join-Path $buildRoot ('installer-'+[guid]::NewGuid().ToString('N'))))
try {
 [IO.Compression.ZipFile]::ExtractToDirectory($archive,$stage)
 $source=Join-Path $stage 'GeoRoute.wxs'
 & $PythonExe -I (Join-Path $PSScriptRoot 'installer\generate_wix.py') --root (Join-Path $stage 'GeoRoute') --version $Version --output $source
 if($LASTEXITCODE -ne 0){throw 'MSI source generation failed.'}
 $obj=Join-Path $stage 'GeoRoute.wixobj'
 & (Join-Path $WixBin 'candle.exe') -nologo -arch x64 -ext WixUIExtension -out $obj $source
 if($LASTEXITCODE -ne 0){throw 'MSI compilation failed.'}
 New-Item -ItemType Directory -Path $output -Force|Out-Null
 $setup=Join-Path $output ('GeoRoute-Setup-'+$Version+'-x64.msi')
 & (Join-Path $WixBin 'light.exe') -nologo -ext WixUIExtension -cultures:ru-ru -out $setup $obj
 if($LASTEXITCODE -ne 0){throw 'MSI linking/validation failed.'}
 Remove-Item -LiteralPath ([IO.Path]::ChangeExtension($setup,'.wixpdb')) -ErrorAction SilentlyContinue
 $hash=(Get-FileHash -LiteralPath $setup).Hash.ToLowerInvariant()
 [IO.File]::WriteAllText(($setup+'.sha256'),($hash+'  '+[IO.Path]::GetFileName($setup)+"`n"),[Text.Encoding]::ASCII)
 Write-Output ('Built '+$setup+' from verified portable payload '+$expected)
} finally {
 $resolved=[IO.Path]::GetFullPath($stage)
 if(-not $resolved.StartsWith(([IO.Path]::GetFullPath($buildRoot)+'\'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^installer-[a-f0-9]{32}$'){throw 'Unexpected installer staging path.'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

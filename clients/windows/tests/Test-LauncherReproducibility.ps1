#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ArchivePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$clientRoot=Split-Path $PSScriptRoot -Parent
$buildRoot=[IO.Path]::GetFullPath((Join-Path $clientRoot '.build')).TrimEnd('\')+'\'
$output=[IO.Path]::GetFullPath((Join-Path $buildRoot ('repro-'+[guid]::NewGuid().ToString('N'))))
$zip=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ArchivePath))
try {
 $entry=@($zip.Entries | Where-Object {$_.FullName.Replace('\','/') -eq 'GeoRoute/GeoRoute.exe'})
 if($entry.Count -ne 1){throw 'Expected exactly one launcher'}
 $input=$entry[0].Open();$sha=[Security.Cryptography.SHA256]::Create()
 try {$expected=[BitConverter]::ToString($sha.ComputeHash($input)).Replace('-','').ToLowerInvariant()}finally{$input.Dispose();$sha.Dispose()}
}finally{$zip.Dispose()}
try {
 $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 & $shell -NoProfile -File (Join-Path $clientRoot '_service\Build-Launcher.ps1') -OutputDirectory $output -NoLegacyAlias
 if($LASTEXITCODE -ne 0){throw 'Independent launcher rebuild failed'}
 $actual=(Get-FileHash -LiteralPath (Join-Path $output 'GeoRoute.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
 if($actual -cne $expected){throw ('Launcher is not reproducible: '+$expected+' != '+$actual)}
 Write-Output ('Independent launcher rebuild matched SHA-256 '+$actual)
}finally{
 $resolved=[IO.Path]::GetFullPath($output)
 if(-not $resolved.StartsWith($buildRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^repro-[a-f0-9]{32}$'){throw 'Refusing to remove an unexpected rebuild directory'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}

#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Bin,[switch]$NoLegacyAlias,[string]$OutputDirectory,[switch]$Tests)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Собирайте launcher через системный Windows PowerShell 5.1.' }
$taskService = $PSScriptRoot
$taskOutputDirectory = if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}elseif($Bin){Join-Path $taskService 'bin'}else{Split-Path $taskService -Parent}
New-Item -ItemType Directory -Path $taskOutputDirectory -Force | Out-Null
$taskOutput = Join-Path $taskOutputDirectory 'GeoRoute.exe'
$taskProject=Join-Path $taskService 'GeoRoute.Launcher.vcxproj'
$taskIntermediate=Join-Path (Split-Path $taskService -Parent) ('.build\native-obj-'+[bool]$Tests)
$taskVswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if(-not(Test-Path -LiteralPath $taskVswhere)){throw 'Для сборки нужны Visual Studio C++ Build Tools. Готовому приложению компилятор не нужен.'}
$taskVs=& $taskVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(-not $taskVs){throw 'Не найдены Visual Studio C++ Build Tools.'}
$taskMsbuild=Join-Path $taskVs 'MSBuild\Current\Bin\amd64\MSBuild.exe'
$taskTools=[version]([IO.File]::ReadAllText((Join-Path $taskVs 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim())
$taskToolset=if($taskTools.Minor -ge 50){'v145'}elseif($taskTools.Minor -ge 30){'v143'}else{'v142'}
& $taskMsbuild $taskProject /t:Rebuild /nologo /verbosity:minimal /p:Configuration=Release /p:Platform=x64 ('/p:PlatformToolset='+$taskToolset) ('/p:OutDir='+$taskOutputDirectory.TrimEnd('\')+'\') ('/p:IntDir='+$taskIntermediate.TrimEnd('\')+'\') ('/p:LauncherTests='+([bool]$Tests).ToString().ToLowerInvariant())
if($LASTEXITCODE -ne 0){throw 'Сборка Win32 launcher завершилась ошибкой.'}
if($Tests){Write-Output 'Built launcher protocol tests';return}
Write-Output ('Built ' + $taskOutput)

# Keep old shortcuts/startup entries compatible during migration.
if(-not $NoLegacyAlias){
Copy-Item -LiteralPath $taskOutput -Destination (Join-Path $taskOutputDirectory 'NextDNS.exe') -Force

}

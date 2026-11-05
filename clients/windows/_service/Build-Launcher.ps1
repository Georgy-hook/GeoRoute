#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Bin,[switch]$NoLegacyAlias,[string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Собирайте launcher через системный Windows PowerShell 5.1.' }
$taskService = $PSScriptRoot
$taskOutputDirectory = if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}elseif($Bin){Join-Path $taskService 'bin'}else{Split-Path $taskService -Parent}
New-Item -ItemType Directory -Path $taskOutputDirectory -Force | Out-Null
$taskOutput = Join-Path $taskOutputDirectory 'GeoRoute.exe'
$taskProject=Join-Path $taskService 'GeoRoute.Launcher.csproj'
$taskIntermediate=Join-Path (Split-Path $taskService -Parent) '.build\launcher-obj'
if(-not(Get-Command dotnet.exe -ErrorAction SilentlyContinue)){throw 'Для сборки из исходников установите .NET SDK 10. Готовому приложению SDK не нужен.'}
& dotnet.exe build $taskProject --configuration Release --no-incremental --output $taskOutputDirectory --nologo --verbosity minimal ('/p:BaseIntermediateOutputPath='+$taskIntermediate.Replace('\','/')+'/')
if($LASTEXITCODE -ne 0){throw 'Сборка launcher через .NET SDK завершилась ошибкой.'}
Copy-Item -LiteralPath (Join-Path $taskService 'NextDNS.runtime.config') -Destination ($taskOutput + '.config') -Force
Write-Output ('Built ' + $taskOutput)

# Keep old shortcuts/startup entries compatible during migration.
if(-not $NoLegacyAlias){
Copy-Item -LiteralPath $taskOutput -Destination (Join-Path $taskOutputDirectory 'NextDNS.exe') -Force
Copy-Item -LiteralPath ($taskOutput+'.config') -Destination (Join-Path $taskOutputDirectory 'NextDNS.exe.config') -Force

}

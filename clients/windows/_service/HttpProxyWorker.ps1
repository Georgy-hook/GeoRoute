#Requires -Version 5.1
param([ValidateSet('Check','Enable')][string]$Mode='Check',[Parameter(Mandatory=$true)][string]$Server,[Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HttpProxy.ps1')
$runRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'run-results'))
if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResultPath)) -ine $runRoot -or [IO.Path]::GetFileName($ResultPath) -cnotmatch '^gui-\d{8}-\d{6}-[a-f0-9]{8}\.json$'){throw 'Некорректный путь результата.'}
try {
 $report=Test-ChatGptHttpProxy $Server
 if($Mode -eq 'Enable' -and $report.Ok){
  $state=Set-ChatGptHttpProxy $PSScriptRoot $Server
  if(-not $state.Enabled){throw 'Применение настройки Windows не подтверждено.'}
  $report.Message+=' Настройка Windows сохранена; менеджер можно закрыть.'
 }
} catch {$report=[pscustomobject]@{At=(Get-Date).ToString('o');Server=$Server;Ok=$false;Country='';Http=0;Message=$_.Exception.Message;AttachmentsVerified=$false}}
[IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'state'))|Out-Null
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'state\http-proxy-check.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ResultPath -Encoding UTF8

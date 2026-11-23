#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RequestPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Warp.ps1')
$request=Get-Content -Raw -LiteralPath $RequestPath -Encoding UTF8|ConvertFrom-Json
$result=@{Status='error';Mode=[string]$request.Mode;At=[DateTimeOffset]::Now.ToString('o')}
try{
 switch($request.Mode){
  Install {
   $runtime=Initialize-WarpRuntime $PSScriptRoot
   $setupResult=Join-Path (Split-Path $RequestPath -Parent) ('warp-'+[guid]::NewGuid().ToString('N')+'.setup.json')
   $setupArguments=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'WarpSetup.ps1')+'"'),'-ExpectedUserSid',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'-RuntimeDirectory',('"'+$runtime+'"'),'-ResultPath',('"'+$setupResult+'"'))
   $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $setupArguments -Verb RunAs -WindowStyle Hidden -PassThru
   if(-not $process.WaitForExit(300000)){throw 'Установка ещё не завершилась. Проверьте запрос Windows и журнал.'}
   $answer=Get-Content -Raw -LiteralPath $setupResult -Encoding UTF8|ConvertFrom-Json
   if($answer.Status -ne 'ok'){throw $answer.Error}
   $result.Message='WARP установлен. Автоподключение можно включить отдельно.'
  }
  Uninstall {
   $setupResult=Join-Path (Split-Path $RequestPath -Parent) ('warp-'+[guid]::NewGuid().ToString('N')+'.setup.json')
   $setupArguments=@('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $PSScriptRoot 'WarpSetup.ps1')+'"'),'-Mode','Uninstall','-ExpectedUserSid',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'-ResultPath',('"'+$setupResult+'"'))
   $process=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $setupArguments -Verb RunAs -WindowStyle Hidden -PassThru
   if(-not $process.WaitForExit(60000)){throw 'Удаление не завершилось вовремя.'}
   $answer=Get-Content -Raw -LiteralPath $setupResult -Encoding UTF8|ConvertFrom-Json
   if($answer.Status -ne 'ok'){throw $answer.Error}
   $result.Message='Компонент WARP удалён. Остальные подключения сохранены.'
  }
  Connect {
   $profile=if($request.ProfileId){Get-WarpProfile $PSScriptRoot $request.ProfileId}else{$null}
   $null=Invoke-WarpControl Connect $profile
   $result.Message='Подключено через WARP и GeoHide.'
  }
  Disconnect {$null=Invoke-WarpControl Disconnect;$result.Message='Подключение WARP выключено.'}
  AutoOn {$null=Invoke-WarpControl AutoOn;$result.Message='WARP будет подключаться при запуске Windows.'}
  AutoOff {$null=Invoke-WarpControl AutoOff;$result.Message='Автоподключение WARP выключено.'}
  default {throw 'Неизвестная команда WARP.'}
 }
 $result.Status='ok'
}catch{$result.Error=$_.Exception.Message}
$result|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $request.ResultPath -Encoding UTF8
if($result.Status -ne 'ok'){exit 1}

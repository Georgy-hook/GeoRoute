#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'Warp.ps1')
$script:warpRun=$null
$script:warpUiSync=$false
$script:warpUiAt=[datetime]::MinValue
function Update-TaskWarp([switch]$Force){
 if(-not $script:taskUi.WarpStatus){return}
 if(-not $Force -and ((Get-Date)-$script:warpUiAt).TotalSeconds -lt 3){return}
 $script:warpUiAt=Get-Date
 $state=Get-WarpState
 $script:warpUiSync=$true
 try{
  $script:taskUi.WarpStatus.Text=Get-WarpTitle $state
  $script:taskUi.WarpStatus.Foreground=Get-TaskBrush $(if($state.Connected){'#91F2D2'}elseif($state.State -in @('retrying','cleanup-required','unknown')){'#F6C56B'}else{'#A4B7CE'})
  $script:taskUi.WarpDetail.Text=if($state.Installed){'Сохранённый маршрут: '+$state.ProfileName+$(if(@($state.Addresses).Count){' · '+(@($state.Addresses)-join ', ')}else{''})+$(if($state.Error){("`n"+(Get-WarpProblem $state.Error))}else{''})}else{'Компонент устанавливается отдельно. При первой установке Windows запросит подтверждение администратора.'}
  $script:taskUi.WarpAutoConnect.IsChecked=[bool]$state.AutoStart
  $script:taskUi.WarpPreferred.IsChecked=Test-WarpPreferred $script:taskRoot
  $idle=-not $script:taskBusy -and -not $script:warpRun
  $script:taskUi.WarpInstallButton.Visibility=if($state.Installed){'Collapsed'}else{'Visible'}
  foreach($name in @('WarpAutoConnect','WarpPreferred','WarpPowerButton','WarpLogsButton','WarpRemoveButton')){$script:taskUi[$name].Visibility=if($state.Installed){'Visible'}else{'Collapsed'}}
  $script:taskUi.WarpInstallButton.IsEnabled=$idle
  $script:taskUi.WarpPowerButton.IsEnabled=($idle -and $state.Installed -and $state.CanControl)
  $script:taskUi.WarpPowerButton.Content=if($state.Requested -or $state.Connected){'Отключить WARP'}else{'Подключить WARP'}
  $script:taskUi.WarpAutoConnect.IsEnabled=($idle -and $state.CanControl)
  $script:taskUi.WarpPreferred.IsEnabled=($idle -and $state.CanControl)
  $script:taskUi.WarpRemoveButton.IsEnabled=($idle -and $state.Installed -and $state.CanControl)
  $script:taskUi.WarpLogsButton.IsEnabled=$state.Installed
 }finally{$script:warpUiSync=$false}
}
function Start-TaskWarpAction([ValidateSet('Connect','Disconnect','AutoOn','AutoOff','Install','Uninstall')][string]$Mode,[string]$ProfileId=''){
 if($script:taskBusy -or $script:warpRun -or $SmokeTest -or $RenderPreview){return}
 try{
  $directory=Join-Path $script:taskRoot 'run-results';[IO.Directory]::CreateDirectory($directory)|Out-Null
  if((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка результатов не должна быть ссылкой.'}
  $prefix=Join-Path $directory ('warp-'+[guid]::NewGuid().ToString('N'))
  $requestPath=$prefix+'.request.json';$resultPath=$prefix+'.result.json'
  @{Mode=$Mode;ProfileId=$ProfileId;ResultPath=$resultPath}|ConvertTo-Json|Set-Content -LiteralPath $requestPath -Encoding UTF8
  $process=Start-Process -FilePath $script:taskShell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:taskRoot 'WarpCommand.ps1')+'"'),'-RequestPath',('"'+$requestPath+'"')) -WindowStyle Hidden -PassThru
  $script:warpRun=[pscustomobject]@{Process=$process;Mode=$Mode;RequestPath=$requestPath;ResultPath=$resultPath;ProfileId=$ProfileId}
  Set-TaskBusy $true
  $script:taskUi.ActionTitle.Text=switch($Mode){Install{'Устанавливаю WARP…'}Uninstall{'Удаляю WARP…'}Connect{'Подключаю WARP…'}Disconnect{'Отключаю WARP…'}default{'Сохраняю автоподключение…'}}
  $script:taskUi.ActivityDetail.Text=if($Mode -eq 'Install'){'Загрузка проверенных компонентов; затем подтвердите установку в Windows.'}else{'Действие выполняется в фоне. Повторное нажатие временно недоступно.'}
  Add-TaskLog $script:taskUi.ActionTitle.Text -Kind Actions
  Update-TaskWarp -Force
 }catch{Add-TaskLog $_.Exception.Message -Kind Problems;Set-TaskBusy $false;Update-TaskWarp -Force}
}
function Poll-TaskWarp {
 if($script:warpRun -and $script:warpRun.Process.HasExited){
  $run=$script:warpRun
  try{
   $answer=Get-Content -Raw -LiteralPath $run.ResultPath -Encoding UTF8|ConvertFrom-Json
   if($answer.Status -ne 'ok'){throw $answer.Error}
   if($run.Mode -eq 'Install'){Save-GeoGuiPreference $script:taskSettingsPath @{WarpPreferred=$true}}
   if($run.Mode -eq 'Uninstall'){Save-GeoGuiPreference $script:taskSettingsPath @{WarpPreferred=$false}}
   $script:taskUi.ActionTitle.Text=$answer.Message
   $script:warpObservationState=$null
   $script:taskUi.ActivityDetail.Text='Готово. Автоподключение соединения и запуск окна GeoRoute настраиваются независимо.'
   Add-TaskLog $answer.Message -Kind Actions
  }catch{$script:taskUi.ActionTitle.Text='Действие WARP не завершено';$script:taskUi.ActivityDetail.Text=$_.Exception.Message;Add-TaskLog $_.Exception.Message -Kind Problems}
  finally{$run.Process.Dispose();$script:warpRun=$null;Set-TaskBusy $false;Update-TaskWarp -Force;[void](Update-TaskStatus);Update-GeoHome -Force}
 }
 Update-TaskWarp
}
function Initialize-TaskWarp {
 Update-TaskWarp -Force
 $script:taskUi.WarpInstallButton.Add_Click({Start-TaskWarpAction Install})
 $script:taskUi.WarpPowerButton.Add_Click({$value=Get-WarpState;Start-TaskWarpAction $(if($value.Requested -or $value.Connected){'Disconnect'}else{'Connect'})})
 $script:taskUi.WarpAutoConnect.Add_Checked({if(-not $script:warpUiSync){Start-TaskWarpAction AutoOn}})
 $script:taskUi.WarpAutoConnect.Add_Unchecked({if(-not $script:warpUiSync){Start-TaskWarpAction AutoOff}})
 foreach($event in @('Add_Checked','Add_Unchecked')){
  $script:taskUi.WarpPreferred.$event({if(-not $script:warpUiSync){Save-GeoGuiPreference $script:taskSettingsPath @{WarpPreferred=($script:taskUi.WarpPreferred.IsChecked -eq $true)};Update-GeoHome -Force}})
 }
 $script:taskUi.WarpRemoveButton.Add_Click({Start-TaskWarpAction Uninstall})
 $script:taskUi.WarpLogsButton.Add_Click({$paths=Get-WarpPaths;if(Test-Path -LiteralPath $paths.Public){Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"'+$paths.Public+'"')|Out-Null}})
}
function Get-WarpHomeState([string]$Root,[string]$HostsText,$State=$null){
 if(-not(Test-WarpPreferred $Root)){return $null}
 if(-not $State){$State=Get-WarpState}
 if(-not $State.Installed -or -not $State.CanControl){return $null}
 if($HostsText -match '(?m)^# BEGIN CHATGPT-US-WINDOWS' -and -not $HostsText.Contains('# Transport: GeoRouteWARP')){return $null}
 $on=$State.Requested -or $HostsText.Contains('# Transport: GeoRouteWARP')
 $kind=if($State.Connected){'ready'}elseif($State.State -eq 'cleanup-required'){'error'}elseif($on){'checking'}else{'off'}
 [pscustomobject]@{On=[bool]$on;State=$kind;Title=$(if($State.Connected){'Включено · WARP'}else{Get-WarpTitle $State});Detail=$(if($State.Connected){'Маршрут GeoHide работает через WARP. Проверка HTTPS пройдена; остальные подключения сохранены.'}elseif($on){'Восстанавливаю только сохранённый маршрут GeoHide. Можно выключить подключение.'}else{'Нажмите «Включить» для сохранённого маршрута WARP. Другой профиль: «Серверы → Подключить».'});Transport='Warp';ProfileName=$State.ProfileName;CanConnect=$true}
}

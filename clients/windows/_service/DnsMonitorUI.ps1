$script:dnsMonitorRun=$null;$script:dnsMonitorReport=$null
function Test-DnsMonitorFresh($Row) {
 if(-not $Row -or $Row.state -ne 'complete' -or -not $Row.ready){return $false}
 $at=[datetime]::MinValue
 return ([datetime]::TryParse([string]$Row.at,[ref]$at) -and ((Get-Date)-$at).TotalSeconds -ge -60 -and ((Get-Date)-$at).TotalMinutes -lt 5)
}
function Get-DnsMonitorSelection($Row) {
 if(-not(Test-DnsMonitorFresh $Row)){throw 'Выберите DNS с успешной проверкой не старше пяти минут.'}
 return [pscustomobject]@{url=[string]$Row.url;servers=@($Row.servers)}
}
function Set-DnsMonitorBusy([bool]$Busy) {
 $script:taskUi.DnsMonitorCheck.IsEnabled=-not $Busy
 $script:taskUi.DnsMonitorCheck.Content=if($Busy){'Проверяю DNS…'}else{'Проверить все DNS'}
 $script:taskUi.DnsMonitorProgress.Visibility=if($Busy){'Visible'}else{'Collapsed'}
 $script:taskUi.DnsMonitorUse.IsEnabled=$false
}
function Update-DnsMonitorSelection {
 $selected=$script:taskUi.DnsMonitorGrid.SelectedItem
 $row=@(if($selected){$script:dnsMonitorReport.rows|Where-Object url -eq $selected.Url|Select-Object -First 1})
 $ready=-not $script:dnsMonitorRun -and -not $script:taskBusy -and $row.Count -eq 1 -and (Test-DnsMonitorFresh $row[0])
 $script:taskUi.DnsMonitorUse.IsEnabled=$ready
 $script:taskUi.DnsMonitorSelected.Text=if($ready){$row[0].name+' · '+$row[0].ms+' мс · можно выбрать'}elseif($selected){'Для выбора нужна успешная свежая проверка DNS'}else{'Выберите отвечающий DNS в таблице'}
}
function Update-DnsMonitorRows {
 $filter=$script:taskUi.DnsMonitorSearch.Text.Trim()
 $selected=$script:taskUi.DnsMonitorGrid.SelectedItem
 $rows=@(foreach($r in @($script:dnsMonitorReport.rows|Where-Object {$_})){
  if($filter -and ($r.name+' '+$r.url).IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
  $pending=$r.state -in @('queued','checking')
  $fresh=Test-DnsMonitorFresh $r
  $label=if($r.state -eq 'queued'){'В очереди…'}elseif($r.state -eq 'checking'){'Проверяю…'}elseif($r.state -eq 'interrupted'){'Не завершено'}elseif($fresh){'DNS отвечает'}elseif($r.ready){'Проверка устарела'}else{'Нет ответа DNS'}
  $color=if($pending){'#A4D5F2'}elseif($fresh){'#91F2D2'}elseif($r.ready){'#F6C56B'}else{'#FFAC9A'}
  $code=switch($r.id){'geohide-eu'{'EU'}'geohide-us'{'US'}'geohide-ru'{'RU'}default{''}}
  $time=[datetime]::MinValue;$checked=if([datetime]::TryParse([string]$r.at,[ref]$time)){$time.ToLocalTime().ToString('dd.MM HH:mm:ss')}else{'—'}
  [pscustomobject]@{Name=([string]$r.name -replace ' — другой провайдер$','' -replace ' — сообщается о блокировке$','');Url=$r.url;Status=$label;Color=$color;Loading=$(if($pending){'Visible'}else{'Collapsed'});Latency=$(if($null -ne $r.ms){[string]$r.ms+' мс'}else{'—'});Addresses=(@($r.servers) -join ', ');Checked=$checked;Error=[string]$r.error;Flag=$(if($code){Get-TaskImage ('flag-'+$code+'.png')}else{$null});Ready=$fresh;SortLatency=$(if($null -ne $r.ms){[double]$r.ms}else{[double]::MaxValue})}
 })
 if(-not $script:dnsMonitorReport.running){$rows=@($rows|Sort-Object @{Expression='Ready';Descending=$true},SortLatency,Name)}
 $script:taskUi.DnsMonitorGrid.ItemsSource=$rows
 if($selected){$script:taskUi.DnsMonitorGrid.SelectedItem=@($rows|Where-Object Url -eq $selected.Url|Select-Object -First 1)[0]}
 Update-DnsMonitorSelection
}
function Complete-DnsMonitor {
 foreach($r in @($script:dnsMonitorReport.rows)){if($r.state -in @('queued','checking')){$r.state='interrupted';$r.ready=$false;$r.error='Проверка не завершена'}}
 if($script:dnsMonitorReport){$script:dnsMonitorReport.running=$false}
 if($script:dnsMonitorRun){$script:dnsMonitorRun.Process.Dispose()}
 $script:dnsMonitorRun=$null
 Set-DnsMonitorBusy $false;Update-DnsMonitorRows
}
function Start-DnsMonitor {
 if($script:dnsMonitorRun -or $SmokeTest -or $RenderPreview){return}
 try{
  $providers=(Get-Content (Join-Path $script:taskRoot 'dns-providers.json') -Raw -Encoding UTF8|ConvertFrom-Json).providers
  $rows=@($providers|ForEach-Object {[pscustomobject]@{id=$_.id;name=$_.name;url=$_.url;servers=@();state='queued';ready=$false;at=$null;ms=$null;error=''}})
  $script:dnsMonitorReport=[pscustomobject]@{rows=$rows;running=$true;completed=0;total=$rows.Count;at=(Get-Date).ToString('o')}
  Set-DnsMonitorBusy $true;Update-DnsMonitorRows
  $runRoot=Join-Path $script:taskRoot 'run-results';[IO.Directory]::CreateDirectory($runRoot)|Out-Null
  if((Get-Item $runRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка результатов не должна быть ссылкой.'}
  $id=[guid]::NewGuid().ToString('N');$path=Join-Path $runRoot ('dns-monitor-'+$id+'.json')
  $python=Join-Path $script:taskRoot 'bridge\python\python.exe'
  if(-not(Test-Path $python)){throw 'Нет встроенного Python. Используйте полный пакет приложения.'}
  $args=@('-I',('"'+(Join-Path $script:taskRoot 'bridge\dns_monitor.py')+'"'),'--providers',('"'+(Join-Path $script:taskRoot 'dns-providers.json')+'"'),'--output',('"'+$path+'"'),'--run-id',$id)
  $custom=Join-Path $script:taskRoot 'selective-dns.json'
  if(Test-Path $custom){$args+=@('--custom',('"'+$custom+'"'))}
  $process=Start-Process -FilePath $python -ArgumentList $args -WindowStyle Hidden -PassThru
  $script:dnsMonitorRun=[pscustomobject]@{Process=$process;Path=$path;Id=$id;At=(Get-Date);Stamp=''}
  $script:taskUi.DnsMonitorStatus.Text='Проверяю DoH. DNS Windows не меняется; провайдерам отправляется только example.com.'
 }catch{Complete-DnsMonitor;$script:taskUi.DnsMonitorStatus.Text='Не удалось начать проверку: '+$_.Exception.Message}
}
function Poll-DnsMonitor {
 if(-not $script:dnsMonitorRun){
  $stale=@($script:taskUi.DnsMonitorGrid.ItemsSource|Where-Object {$_.Ready -and $_.Status -eq 'DNS отвечает'}|Where-Object {
   $url=$_.Url;$raw=@($script:dnsMonitorReport.rows|Where-Object url -eq $url|Select-Object -First 1)
   $raw.Count -and -not(Test-DnsMonitorFresh $raw[0])
  })
  if($script:taskPage -eq 'Dns' -and $stale.Count){Update-DnsMonitorRows}else{Update-DnsMonitorSelection};return
 }
 $run=$script:dnsMonitorRun
 try{
  if(Test-Path $run.Path){
   $stamp=[IO.File]::GetLastWriteTimeUtc($run.Path).ToString('o')
   if($stamp -ne $run.Stamp){
    $report=Get-Content $run.Path -Raw -Encoding UTF8|ConvertFrom-Json
    if($report.runId -eq $run.Id){$run.Stamp=$stamp;$script:dnsMonitorReport=$report;Update-DnsMonitorRows;$script:taskUi.DnsMonitorStatus.Text='Проверено '+$report.completed+' из '+$report.total+' DNS · HTTPS + DNS-ответ · настройки Windows не менялись'}
   }
  }
 }catch{}
 if($run.Process.HasExited){
  $ok=$run.Process.ExitCode -eq 0
  Complete-DnsMonitor
  if(-not $ok){$script:taskUi.DnsMonitorStatus.Text='Проверка прервалась. Незавершённые строки не считаются недоступными; повторите проверку.'}
 }elseif(((Get-Date)-$run.At).TotalSeconds -gt 150){
  $run.Process.Kill();Complete-DnsMonitor;$script:taskUi.DnsMonitorStatus.Text='Тайм-аут DNS-проверки. Можно повторить; сетевые настройки не менялись.'
 }
}
function Stop-DnsMonitor {
 if($script:dnsMonitorRun){try{if(-not $script:dnsMonitorRun.Process.HasExited){$script:dnsMonitorRun.Process.Kill()};$script:dnsMonitorRun.Process.Dispose()}catch{};$script:dnsMonitorRun=$null}
}
function Initialize-DnsMonitor {
 $script:taskUi.DnsMonitorCheck.Add_Click({Start-DnsMonitor})
 $script:taskUi.DnsMonitorSearch.Add_TextChanged({Update-DnsMonitorRows})
 $script:taskUi.DnsMonitorGrid.Add_SelectionChanged({Update-DnsMonitorSelection})
 $script:taskUi.DnsMonitorUse.Add_Click({
  try{$selected=$script:taskUi.DnsMonitorGrid.SelectedItem;$raw=@($script:dnsMonitorReport.rows|Where-Object url -eq $selected.Url|Select-Object -First 1);$provider=Get-DnsMonitorSelection $raw[0];Show-DnsSitesDialog $provider}catch{$script:taskUi.DnsMonitorStatus.Text=$_.Exception.Message}
 })
 $script:taskUi.MonitorServersTab.Add_Checked({if($script:taskPage -ne 'Geo'){Set-TaskPage 'Geo'}})
 $script:taskUi.MonitorDnsTab.Add_Checked({if($script:taskPage -ne 'Dns'){Set-TaskPage 'Dns'}})
 Set-DnsMonitorBusy $false
}

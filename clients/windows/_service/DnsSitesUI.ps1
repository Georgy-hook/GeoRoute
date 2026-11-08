. (Join-Path $PSScriptRoot 'SelectiveDns.ps1')
function Update-DnsSitesSummary([switch]$Force) {
 if(-not $Force -and $script:dnsSummaryAt -and ((Get-Date)-$script:dnsSummaryAt).TotalSeconds -lt 30){return}
 $script:dnsSummaryAt=Get-Date
 $script:dnsCurrentState=Get-SelectiveDnsStatus
 if($script:taskUi.ContainsKey('DnsSitesSummary')){$script:taskUi.DnsSitesSummary.Text=$script:dnsCurrentState.Text}
 if($script:taskUi.ContainsKey('HomeDnsSummary')){$script:taskUi.HomeDnsSummary.Text='Другие сайты: '+$script:dnsCurrentState.Text}
}
function Get-DnsDialogConfig {
 $ui=$script:dnsDialog.Ui
 $sites=Convert-DnsSiteList $ui.DnsSelectedSites.Text
 return (New-SelectiveDnsConfig $ui.DnsUrl.Text @($ui.DnsServers.Text -split '[\s,;]+'|Where-Object {$_}) $sites ($ui.DnsSubdomains.IsChecked -eq $true))
}
function Set-DnsDialogBusy([bool]$Busy) {
 $ui=$script:dnsDialog.Ui
 foreach($name in @('DnsProvider','DnsUrl','DnsServers','DnsSelectedSites','DnsNewSite','DnsSubdomains','DnsSave','DnsEnable','DnsProbe','DnsDisable','DnsRefreshCatalogue','DnsAddSite','DnsAddCatalogue')){$ui[$name].IsEnabled=-not $Busy}
 $ui.DnsProgress.Visibility=if($Busy){'Visible'}else{'Collapsed'}
}
function Update-DnsCatalogue {
 $filter=$script:dnsDialog.Ui.DnsSearch.Text.Trim()
 $items=@($script:dnsDialog.Catalogue|Where-Object {-not $filter -or $_.IndexOf($filter,[StringComparison]::OrdinalIgnoreCase) -ge 0})
 $script:dnsDialog.Ui.DnsCatalogue.ItemsSource=[string[]]$items
}
function Add-DnsDialogSite([string]$Text) {
 if(-not $Text){return}
 try {
  $site=Convert-DnsSite $Text
  $before=$script:dnsDialog.Ui.DnsSelectedSites.Text
  $sites=Convert-DnsSiteList ($before+"`n"+$site)
  $script:dnsDialog.Ui.DnsSelectedSites.Text=$sites -join "`r`n"
  $script:dnsDialog.Ui.DnsNewSite.Clear()
  $script:dnsDialog.Ui.DnsActionStatus.Text=if($site -in $script:dnsDialog.Catalogue){'Добавлен '+$site+'. Есть в каталоге GeoHide; для других DNS поддержка может отличаться.'}else{'Добавлен '+$site+'. В каталоге GeoHide его нет: поддержку уточните у DNS-провайдера.'}
 } catch {$script:dnsDialog.Ui.DnsActionStatus.Text=$_.Exception.Message}
}
function Start-DnsDialogAction([string]$Mode) {
 if($script:dnsDialog.Run){return}
 try {
  $config=if($Mode -notin @('Disable','Catalogue')){Get-DnsDialogConfig}else{$null}
  $root=Join-Path $script:taskRoot 'run-results'
  [IO.Directory]::CreateDirectory($root)|Out-Null
  if((Get-Item $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Папка результатов не должна быть ссылкой.'}
  $request=Join-Path $root ('dns-'+[guid]::NewGuid().ToString('N')+'.request.json')
  @{Config=$config;ExpectedUserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $request -Encoding UTF8
  $args=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:taskRoot 'SelectiveDnsSetup.ps1')+'"'),'-Mode',$Mode,'-RequestPath',('"'+$request+'"'))
  Set-DnsDialogBusy $true
  $script:dnsDialog.Ui.DnsActionStatus.Text=if($Mode -in @('Enable','Disable')){'Подтвердите Windows. Проверка и применение могут занять до минуты…'}elseif($Mode -eq 'Catalogue'){'Обновляю каталог GeoHide…'}else{'Проверяю DNS по HTTPS. Сетевые настройки не меняются…'}
  $start=@{FilePath=$script:taskShell;ArgumentList=$args;WindowStyle='Hidden';PassThru=$true;ErrorAction='Stop'}
  if($Mode -in @('Enable','Disable')){$start.Verb='RunAs'}
  if($Mode -in @('Enable','Disable')){Set-TaskBusy $true}
  $process=Start-Process @start
  $script:dnsDialog.Run=[pscustomobject]@{Process=$process;Mode=$Mode;Request=$request;Result=$request.Replace('.request.json','.result.json');At=(Get-Date);Config=$config}
 } catch {$script:dnsDialog.Ui.DnsActionStatus.Text='Не выполнено: '+$_.Exception.Message;Set-DnsDialogBusy $false;if($Mode -in @('Enable','Disable')){Set-TaskBusy $false}}
}
function Poll-DnsDialogAction {
 if(-not $script:dnsDialog -or -not $script:dnsDialog.Run){return}
 $run=$script:dnsDialog.Run
 if(-not $run.Process.HasExited){
  if($run.Mode -in @('Probe','Catalogue') -and ((Get-Date)-$run.At).TotalSeconds -gt 60){$run.Process.Kill();$script:dnsDialog.Ui.DnsActionStatus.Text='Тайм-аут проверки. Подключение не менялось.'}else{return}
 }
 try {
  if(-not(Test-Path -LiteralPath $run.Result)){throw 'Действие завершилось без отчёта. Откройте окно заново и проверьте состояние перед повтором.'}
  $r=Get-Content -LiteralPath $run.Result -Raw -Encoding UTF8|ConvertFrom-Json
  if($r.status -ne 'ok'){
   $detail=@(if($r.PSObject.Properties['rows']){$r.rows|ForEach-Object {$_.server+': '+$_.error}}) -join '; '
   throw (([string]$r.error)+$(if($detail){' · '+$detail}else{''}))
  }
  if($run.Mode -eq 'Catalogue'){
   $cache=Join-Path $script:taskRoot 'dns-catalogue.json'
   [IO.File]::WriteAllText($cache,($r|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
   $script:dnsDialog.Catalogue=[string[]]@($r.domains)
   Update-DnsCatalogue
   $script:dnsDialog.Ui.DnsCatalogueInfo.Text='Обновлён '+(Get-Date -Format 'dd.MM HH:mm')+' · '+$r.domains.Count+' доменов'
   $message='Каталог обновлён. Новые сайты не добавляются в ваше подключение автоматически.'
  }elseif($run.Mode -eq 'Probe'){
   $rows=@($r.rows|ForEach-Object {if($_.ok){$_.server+': '+$_.ms+' мс'+$(if($_.rcode -eq 3){' · NXDOMAIN, сайт не найден'}else{''})}else{$_.server+': '+$_.error}})
   $message=[string]$r.message+' '+($rows -join '; ')
  }else{
   if($run.Mode -eq 'Enable'){Write-SelectiveDnsConfig $script:taskRoot $r.settings}
   $message=[string]$r.message
   Add-TaskLog $message
  }
  $script:dnsDialog.Ui.DnsActionStatus.Text=$message
 } catch {$script:dnsDialog.Ui.DnsActionStatus.Text='Не выполнено: '+$_.Exception.Message}
 finally {
  $run.Process.Dispose();$script:dnsDialog.Run=$null;Set-DnsDialogBusy $false
  if($run.Mode -in @('Enable','Disable')){Set-TaskBusy $false}
  $script:dnsDialog.Ui.DnsCurrentStatus.Text=(Get-SelectiveDnsStatus).Text
  Update-DnsSitesSummary -Force
 }
}
function New-DnsSitesDialog($Owner) {
 [xml]$xml=[IO.File]::ReadAllText((Join-Path $script:taskRoot 'DnsSites.xaml'))
 $reader=[Xml.XmlNodeReader]::new($xml)
 try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
 $window.Resources.Add([Windows.Controls.Primitives.ScrollBar],$script:taskWindow.FindResource([Windows.Controls.Primitives.ScrollBar]))
 if($Owner -and $Owner.IsVisible){$window.Owner=$Owner}
 $window.Height=[Math]::Min(800,[Windows.SystemParameters]::WorkArea.Height-32)
 $ui=@{}
 foreach($node in $xml.SelectNodes('//*[@*[local-name()="Name"]]')){$name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml');if($name){$ui[$name]=$window.FindName($name)}}
 foreach($name in @('DnsAddCatalogue','DnsAddSite','DnsRefreshCatalogue','DnsDisable','DnsSave','DnsProbe','DnsEnable')){$ui[$name].Style=$script:taskWindow.FindResource('ActionButton')}
 $ui.DnsEnable.Background=Get-TaskBrush '#91F2D2';$ui.DnsEnable.Foreground=Get-TaskBrush '#0C2823'
 return @{Window=$window;Ui=$ui;Run=$null;Timer=$null;Catalogue=@()}
}
function Show-DnsSitesDialog {
 if($script:taskBusy -or $SmokeTest -or $RenderPreview){return}
 try {
  $script:dnsDialog=New-DnsSitesDialog $script:taskWindow
  $ui=$script:dnsDialog.Ui
  Register-TaskDarkTitleBar $script:dnsDialog.Window
  Register-TaskDialogKeys $script:dnsDialog.Window
  $config=Read-SelectiveDnsConfig $script:taskRoot
  $ui.DnsUrl.Text=[string]$config.url;$ui.DnsServers.Text=@($config.servers) -join ', '
  $ui.DnsSelectedSites.Text=@($config.domains) -join "`r`n";$ui.DnsSubdomains.IsChecked=[bool]$config.subdomains
  $providers=@((Get-Content (Join-Path $script:taskRoot 'dns-providers.json') -Raw -Encoding UTF8|ConvertFrom-Json).providers)+@([pscustomobject]@{id='custom';name='Свой DNS…';url='';servers=@()})
  $ui.DnsProvider.ItemsSource=$providers
  $selected=@($providers|Where-Object url -eq $config.url|Select-Object -First 1)
  $ui.DnsProvider.SelectedItem=if($selected.Count){$selected[0]}else{$providers[-1]}
  $catalogue=@(Get-Content (Join-Path $script:taskRoot 'geohide-domains.txt') -Encoding UTF8|Where-Object {$_ -and -not $_.StartsWith('#')}|Sort-Object -Unique)
  $cache=Join-Path $script:taskRoot 'dns-catalogue.json'
  if(Test-Path $cache){try{$saved=Get-Content $cache -Raw -Encoding UTF8|ConvertFrom-Json;if($saved.domains.Count -ge 10){$catalogue=@($saved.domains);$ui.DnsCatalogueInfo.Text='Каталог обновлён '+([datetime]$saved.at).ToLocalTime().ToString('dd.MM HH:mm')}}catch{}}
  $script:dnsDialog.Catalogue=[string[]]$catalogue;Update-DnsCatalogue
  $ui.DnsCurrentStatus.Text=(Get-SelectiveDnsStatus).Text
  $ui.DnsProvider.Add_SelectionChanged({$p=$script:dnsDialog.Ui.DnsProvider.SelectedItem;if($p -and $p.id -ne 'custom'){$script:dnsDialog.Ui.DnsUrl.Text=$p.url;$script:dnsDialog.Ui.DnsServers.Text=@($p.servers) -join ', '};$script:dnsDialog.Ui.DnsActionStatus.Text='Список поддерживаемых сайтов зависит от провайдера. Подключение ещё не менялось.'})
  $ui.DnsSearch.Add_TextChanged({Update-DnsCatalogue})
  $ui.DnsAddCatalogue.Add_Click({Add-DnsDialogSite ([string]$script:dnsDialog.Ui.DnsCatalogue.SelectedItem)})
  $ui.DnsCatalogue.Add_MouseDoubleClick({Add-DnsDialogSite ([string]$script:dnsDialog.Ui.DnsCatalogue.SelectedItem)})
  $ui.DnsAddSite.Add_Click({Add-DnsDialogSite $script:dnsDialog.Ui.DnsNewSite.Text})
  $ui.DnsNewSite.Add_KeyDown({param($sender,$e) if($e.Key -eq 'Return'){Add-DnsDialogSite $sender.Text;$e.Handled=$true}})
  $ui.DnsSave.Add_Click({try{$cfg=Get-DnsDialogConfig;Write-SelectiveDnsConfig $script:taskRoot $cfg;$script:dnsDialog.Ui.DnsActionStatus.Text='Список сохранён. Подключение не менялось; нажмите «Включить / обновить», чтобы применить его.'}catch{$script:dnsDialog.Ui.DnsActionStatus.Text=$_.Exception.Message}})
  $ui.DnsProbe.Add_Click({Start-DnsDialogAction 'Probe'})
  $ui.DnsEnable.Add_Click({Start-DnsDialogAction 'Enable'})
  $ui.DnsDisable.Add_Click({Start-DnsDialogAction 'Disable'})
  $ui.DnsRefreshCatalogue.Add_Click({Start-DnsDialogAction 'Catalogue'})
  $script:dnsDialog.Timer=[Windows.Threading.DispatcherTimer]::new();$script:dnsDialog.Timer.Interval=[timespan]::FromMilliseconds(300);$script:dnsDialog.Timer.Add_Tick({Poll-DnsDialogAction});$script:dnsDialog.Timer.Start()
  $script:dnsDialog.Window.Add_Closing({param($sender,$e) if($script:dnsDialog.Run){$e.Cancel=$true;$script:dnsDialog.Ui.DnsActionStatus.Text='Дождитесь завершения текущего действия.'}})
  [void]$script:dnsDialog.Window.ShowDialog()
 } catch {Add-TaskLog ('Не удалось открыть «Сайты и DNS»: '+$_.Exception.Message)}
 finally {if($script:dnsDialog -and $script:dnsDialog.Timer){$script:dnsDialog.Timer.Stop()};$script:dnsDialog=$null;Update-DnsSitesSummary -Force}
}

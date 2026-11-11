. (Join-Path $PSScriptRoot 'GeoHide.ps1')
. (Join-Path $PSScriptRoot 'GeoHideHistory.ps1')
. (Join-Path $PSScriptRoot 'GeoProfileUI.ps1')
. (Join-Path $PSScriptRoot 'Home.ps1')
. (Join-Path $PSScriptRoot 'GeoMonitorState.ps1')
$script:geoRegionFilter='ALL';$script:geoDisplayRows=@()
function Save-GeoGuiPreference([string]$Path,[hashtable]$Values) {
    $settings=[ordered]@{}
    if(Test-Path -LiteralPath $Path){
        $previous=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json
        if($null -eq $previous -or $previous -isnot [pscustomobject]){throw 'Файл настроек повреждён; изменения не сохранены.'}
        foreach($p in $previous.PSObject.Properties){$settings[$p.Name]=$p.Value}
    }
    foreach($key in $Values.Keys){$settings[$key]=$Values[$key]}
    Write-GeoJson $Path ([pscustomobject]$settings)
}
function Update-GeoMonitoringSettingView {
    $off=(Get-GeoMonitoringMinutes) -eq 0
    $script:taskUi.AutoCheckHelp.Text=if($off){'Автопроверки отключены, в том числе при запуске. Проверяйте серверы вручную в «Мониторинге». Настроенное подключение сохраняется.'}else{'Серверы GeoHide, их списки и диагностика подключения проверяются с выбранным интервалом. Ручная проверка доступна в любой момент.'}
    $script:taskUi.AutoCheckHelp.Text+=' Выбор сохраняется автоматически. Уже начатая проверка завершится.'
    if($script:geoReport -and -not $script:geoReport.running){$script:taskUi.GeoStatus.Text='Проверено '+([datetime]$script:geoReport.at).ToString('HH:mm:ss')+' · '+$script:geoReport.interface+' · '+(Get-GeoMonitoringSummary)}
}
function Initialize-GeoMonitoringSettings {
    Set-GeoMonitoringMinutes (Read-GeoMonitoringPreference $script:taskSettingsPath)
    $script:taskUi.AutoCheckInterval.ItemsSource=@(Get-GeoMonitoringChoices)
    $script:taskUi.AutoCheckInterval.SelectedValue=Get-GeoMonitoringMinutes
    Update-GeoMonitoringSettingView
    $script:taskUi.AutoCheckInterval.Add_SelectionChanged({
        param($sender,$eventArgs)
        if($script:monitoringSettingReverting -or $eventArgs.AddedItems.Count -ne 1){return}
        $old=Get-GeoMonitoringMinutes;$value=[int]$eventArgs.AddedItems[0].Minutes
        if($old -eq $value){return}
        try {
            if(-not $SmokeTest -and -not $RenderPreview){Save-GeoGuiPreference $script:taskSettingsPath @{AutoCheckMinutes=$value}}
            Set-GeoMonitoringMinutes $value
            $script:geoAt=Get-Date;$script:geoSourceAt=Get-Date;$script:taskConnectionAttempt=Get-Date
            Update-GeoMonitoringSettingView;Update-GeoHome -Force
        }catch{
            $script:monitoringSettingReverting=$true
            [void]$sender.Dispatcher.BeginInvoke([Action]{
                try{$script:taskUi.AutoCheckInterval.SelectedValue=Get-GeoMonitoringMinutes}finally{$script:monitoringSettingReverting=$false}
            },[Windows.Threading.DispatcherPriority]::Background)
            $script:taskUi.AutoCheckHelp.Text='Не удалось сохранить интервал: '+$_.Exception.Message
        }
    })
}
function Update-GeoMonitorLayout {
    if(-not $script:taskUi.ContainsKey('GeoMonitorHeader')){return}
    $page=$script:taskUi.GeoPage
    if($page.ActualHeight -le 0){return}
    $compact=$page.ActualHeight -lt 640
    $description=if($compact){'Collapsed'}else{'Visible'}
    $art=if($compact -or $page.ActualWidth -lt 1100){'Collapsed'}else{'Visible'}
    if([string]$script:taskUi.GeoHeaderDescription.Visibility -ne $description){$script:taskUi.GeoHeaderDescription.Visibility=$description}
    if([string]$script:taskUi.GeoHeaderArt.Visibility -ne $art){$script:taskUi.GeoHeaderArt.Visibility=$art}
    $legend=if($compact){'Collapsed'}else{'Visible'}
    if([string]$script:taskUi.GeoLegend.Visibility -ne $legend){$script:taskUi.GeoLegend.Visibility=$legend}
    # Keep the editor scrollable without taking the table out of its finite viewport.
    $available=$page.ActualHeight-$script:taskUi.GeoMonitorHeader.ActualHeight-$script:taskUi.GeoLegend.ActualHeight-194
    $limit=[Math]::Max(70,[Math]::Min(400,$available))
    if([Math]::Abs($script:taskUi.GeoDetailsScroll.MaxHeight-$limit) -gt 1){$script:taskUi.GeoDetailsScroll.MaxHeight=$limit}
}
function Initialize-GeoMonitorLayout {
    $script:taskUi.GeoPage.Add_SizeChanged({Update-GeoMonitorLayout})
    $script:taskUi.GeoMonitorHeader.Add_SizeChanged({Update-GeoMonitorLayout})
    $script:taskUi.GeoLegend.Add_SizeChanged({Update-GeoMonitorLayout})
    Update-GeoMonitorLayout
}
$script:geoRun=$null;$script:geoAt=[datetime]::MinValue;$script:geoSourceAt=[datetime]::MinValue;$script:geoReport=$null;$script:geoStamp=''
function Set-GeoMonitorBusy([bool]$Busy) {
    foreach($name in @('GeoCheck','GeoRefresh','GeoAdd')){if($script:taskUi[$name]){$script:taskUi[$name].IsEnabled=-not $Busy}}
    $script:taskUi.GeoCheck.Content=if($Busy){'Проверяю…'}else{'Проверить серверы'}
    $script:taskUi.GeoProgressPanel.Visibility=if($Busy){'Visible'}else{'Collapsed'}
}
function Start-GeoMonitor([switch]$Refresh) {
    if($script:geoRun -or $SmokeTest -or $RenderPreview){return}
    $path=Join-Path $script:taskRoot 'geohide-monitor.json'
    $runId=[guid]::NewGuid().ToString('N')
    try{
        Set-GeoMonitorBusy $true
        $catalog=Get-Content -LiteralPath (Join-Path $script:taskRoot 'geohide-servers.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $settings=Read-GeoSettings $script:taskRoot
        Update-GeoRows (New-GeoPendingReport (@($catalog.servers)+@($settings.manualServers)) $runId $(if($Refresh){'Обновляю списки GeoHide'}else{'Начинаю проверку'}))
        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:taskRoot 'GeoHideWorker.ps1')+'"'),'-ResultPath',('"'+$path+'"'),'-RunId',$runId)
        if($Refresh){$args+='-RefreshSources';$script:geoSourceAt=Get-Date}
        $process=Start-Process -FilePath $script:taskShell -ArgumentList $args -WindowStyle Hidden -PassThru
        $script:geoRun=[pscustomobject]@{Process=$process;Path=$path;At=(Get-Date);Id=$runId}
        $script:geoStamp=''
    }catch{
        Stop-GeoReportLoading $script:geoReport
        if($script:geoReport){Update-GeoHistory $script:geoReport}
        Set-GeoMonitorBusy $false
        $script:geoAt=Get-Date
        $script:taskUi.GeoStatus.Text='Не удалось начать проверку: '+$_.Exception.Message
    }
}
function Update-GeoRows($Report) {
    $script:geoReport=$Report
    Update-GeoHistory $Report
    if($Report.running){
        $script:taskUi.GeoProgress.IsIndeterminate=$Report.completed -eq 0
        $script:taskUi.GeoProgress.Maximum=[Math]::Max(1,[int]$Report.total)
        $script:taskUi.GeoProgress.Value=[int]$Report.completed
        $script:taskUi.GeoProgressText.Text=$Report.phase+' · '+$Report.completed+' из '+$Report.total
    }
    $us=@($Report.rows|Where-Object {$_.Region -eq 'US' -and $_.EligibleUS})
    $eu=@($Report.rows|Where-Object {$_.Region -eq 'EU' -and $_.EligibleEU})
    $draftUS=$script:taskUi.GeoUS.Text;$draftEU=$script:taskUi.GeoEU.Text
    $script:taskUi.GeoUS.ItemsSource=@($Report.rows|Where-Object Region -eq 'US'|ForEach-Object Address)
    $script:taskUi.GeoEU.ItemsSource=@($Report.rows|Where-Object Region -eq 'EU'|ForEach-Object Address)
    $settings=Read-GeoSettings $script:taskRoot
    $script:taskUi.GeoUS.Text=$(if($draftUS){$draftUS}else{$settings.us});$script:taskUi.GeoEU.Text=$(if($draftEU){$draftEU}else{$settings.eu})
    $script:taskUi.GeoStatus.Text=if($Report.running){'Результаты обновляются по мере готовности · '+$Report.interface}else{'Проверено '+([datetime]$Report.at).ToString('HH:mm:ss')+' · '+$Report.interface+' · '+(Get-GeoMonitoringSummary)}
    $script:taskUi.GeoSourceStatus.Text=(@($Report.sources|ForEach-Object{$_.region+': '+$_.checkedAt}) -join ' · ')
    if(@($Report.sourceErrors).Count){$script:taskUi.GeoSourceStatus.Text+=' · Ошибка обновления; сохранён прежний список: '+($Report.sourceErrors -join '; ')}
    if(-not $Report.running -and ((Get-Date)-[datetime]$Report.at).TotalMinutes -lt 5){Sync-GeoRegions $Report}
    Update-GeoProfileCards

}
function Read-GeoRunSnapshot([switch]$Force) {
    try{
        if(Test-Path -LiteralPath $script:geoRun.Path){
            $stamp=[IO.File]::GetLastWriteTimeUtc($script:geoRun.Path).ToString('o')
            if($Force -or $stamp -ne $script:geoStamp){
                $snapshot=Get-Content -LiteralPath $script:geoRun.Path -Raw -Encoding UTF8|ConvertFrom-Json
                if($snapshot.runId -eq $script:geoRun.Id){$script:geoStamp=$stamp;Update-GeoRows $snapshot}
            }
        }
    }catch{$script:taskUi.GeoStatus.Text='Не удалось прочитать результат. Проверка завершится или остановится по тайм-ауту: '+$_.Exception.Message}
}
function Complete-GeoMonitor {
    Stop-GeoReportLoading $script:geoReport
    try{if($script:geoReport){Update-GeoHistory $script:geoReport}}finally{
        try{$script:geoRun.Process.Dispose()}catch{}
        $script:geoRun=$null;$script:geoAt=Get-Date
        Set-GeoMonitorBusy $false
    }
}
function Poll-GeoMonitor {
    Update-GeoEditorState
    if($script:geoRun){
        Read-GeoRunSnapshot
        if($script:geoRun.Process.HasExited){
            $exitCode=$script:geoRun.Process.ExitCode
            Read-GeoRunSnapshot -Force
            Complete-GeoMonitor
            if($exitCode -ne 0){$script:taskUi.GeoStatus.Text='Ошибка диагностики. Незавершённые строки не считаются результатом; повторите проверку.'}
        }elseif(((Get-Date)-$script:geoRun.At).TotalSeconds -gt 600){
            try{$script:geoRun.Process.Kill()}finally{Complete-GeoMonitor}
            $script:taskUi.GeoStatus.Text='Общий тайм-аут проверки. Незавершённые строки отмечены отдельно; можно повторить.'
        }
    }elseif(Test-GeoMonitoringDue $script:geoAt){Start-GeoMonitor -Refresh:(Test-GeoMonitoringDue $script:geoSourceAt)}
}
function Initialize-GeoMonitor {
    Initialize-GeoMonitorLayout
    Initialize-GeoHistory
    foreach($code in @('US','EU','RU')){$script:taskUi[('GeoFlag'+$code)].Source=Get-TaskImage ('flag-'+$code+'.png')}
    $script:taskUi.GeoSearch.Add_TextChanged({Show-GeoFilteredRows})
    foreach($region in @('ALL','US','EU','RU')) {
        $button=$script:taskUi[('GeoFilter'+$region)];$button.Tag=$region
        $button.Add_Click({param($sender,$eventArgs) $script:geoRegionFilter=[string]$sender.Tag;Show-GeoFilteredRows})
    }
    $settings=Read-GeoSettings $script:taskRoot
    $script:taskUi.GeoUS.Text=$settings.us;$script:taskUi.GeoEU.Text=$settings.eu
    $script:taskUi.GeoAuto.IsChecked=[bool]$settings.autoSelect
    $script:taskUi.GeoManual.IsChecked=-not [bool]$settings.autoSelect
    $script:taskUi.GeoRegion.SelectedIndex=0
    $path=Join-Path $script:taskRoot 'geohide-monitor.json'
    if(Test-Path -LiteralPath $path){try{$previous=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;Stop-GeoReportLoading $previous;Update-GeoRows $previous}catch{}}
    Set-GeoMonitorBusy $false
    $script:taskUi.MonitorNavButton.Add_Click({Set-TaskPage 'Geo'})
    $script:taskUi.GeoNavButton.Add_Click({Set-TaskPage 'Geo'})
    $script:taskUi.GeoRefresh.Add_Click({Start-GeoMonitor -Refresh})
    $script:taskUi.GeoCheck.Add_Click({Start-GeoMonitor})
    $script:taskUi.GeoApply.Add_Click({Save-GeoEditor -Connect})
    $script:taskUi.GeoSave.Add_Click({Save-GeoEditor})
    $script:taskUi.GeoAdd.Add_Click({
        try{
            if($script:geoRun){throw 'Дождитесь завершения проверки.'}
            $ip=$script:taskUi.GeoAddress.Text.Trim()
            if(-not (Test-GeoAddress $ip)){throw 'Введите публичный IPv4-адрес сервера.'}
            $s=Read-GeoSettings $script:taskRoot;$region=$script:taskUi.GeoRegion.Text
            if(-not @($s.manualServers|Where-Object{$_.region -eq $region -and $_.address -eq $ip}).Count){$s.manualServers+=@([pscustomobject]@{region=$region;address=$ip;origin='manual'})}
            Write-GeoJson (Join-Path $script:taskRoot 'geohide-settings.json') $s
            Start-GeoMonitor
        }catch{$script:taskUi.GeoStatus.Text=$_.Exception.Message}
    })
    foreach($mode in @('GeoAuto','GeoManual')){
        $script:taskUi[$mode].Add_Click({
            try{
                $s=Read-GeoSettings $script:taskRoot;$s.autoSelect=($script:taskUi.GeoAuto.IsChecked -eq $true)
                Write-GeoJson (Join-Path $script:taskRoot 'geohide-settings.json') $s
                if($s.autoSelect){$script:taskUi.GeoUS.Text=$s.us;$script:taskUi.GeoEU.Text=$s.eu}
                Update-GeoEditorState -Force
            }catch{$script:taskUi.GeoEditorStatus.Text=$_.Exception.Message}
        })
    }
    foreach($field in @('GeoUS','GeoEU')){
        $script:taskUi[$field].AddHandler([Windows.Controls.TextBox]::TextChangedEvent,[Windows.RoutedEventHandler]{Update-GeoEditorState -Force})
    }
    Update-GeoEditorState -Force
}

function Stop-GeoMonitor {
    Stop-GeoReportLoading $script:geoReport
    Set-GeoMonitorBusy $false
    if($script:geoRun){
        try{if(-not $script:geoRun.Process.HasExited){$script:geoRun.Process.Kill()};$script:geoRun.Process.Dispose()}catch{}
        $script:geoRun=$null
    }
}

function Save-GeoEditor([switch]$Connect) {
    $script:geoNotice=''
    try{
        if($script:taskBusy){throw 'Дождитесь завершения применения настроек.'}
        $s=Read-GeoSettings $script:taskRoot
        $s.us=$script:taskUi.GeoUS.Text.Trim();$s.eu=$script:taskUi.GeoEU.Text.Trim()
        $s.autoSelect=($script:taskUi.GeoAuto.IsChecked -eq $true)
        if(-not (Test-GeoAddress $s.us)){throw 'В поле «ChatGPT · US» нужен публичный IPv4, например 192.255.159.240.'}
        if(-not (Test-GeoAddress $s.eu)){throw 'В поле «Вложения · EU» нужен публичный IPv4, например 45.13.237.213.'}
        if($Connect){$candidate=Get-GeoPairAvailability $s.us $s.eu $script:geoReport;if(-not $candidate.Ready){throw ('Подключение недоступно: '+$candidate.Reason+'. Для нового адреса сначала сохраните его без подключения и нажмите «Проверить серверы».')}}
        if(-not $s.autoSelect){
            foreach($pair in @(@('US',$s.us),@('EU',$s.eu))){
                if(-not @($s.manualServers|Where-Object {$_.region -eq $pair[0] -and $_.address -eq $pair[1]}).Count){$s.manualServers+=@([pscustomobject]@{region=$pair[0];address=$pair[1];origin='manual'})}
            }
        }
        Save-GeoProfile $script:taskRoot $s $script:geoReport
        Load-TaskProfiles -Force
        Update-GeoEditorState -Force
        Add-TaskLog ('GeoHide: адреса сохранены в профиле. US '+$s.us+'; EU '+$s.eu+'. Подключение меняется отдельным применением.')
        if($Connect){
            $script:taskUi.GeoEditorStatus.Text='Адреса сохранены. Ожидаю подтверждение Windows и результат применения…'
            $script:geoApplyRequested=$true
            Start-TaskAction 'Apply' (Get-GeoCombinedId $script:taskRoot)
            if(-not $script:taskRun){$script:geoApplyRequested=$false;$script:geoNotice='Применение не подтверждено. Если запрос Windows отменён, подключение не переключено.';Update-GeoEditorState -Force}
        }
    }catch{$script:taskUi.GeoEditorStatus.Text=$_.Exception.Message;$script:taskUi.GeoEditorStatus.Foreground=Get-TaskBrush '#F6C56B'}
}
function Update-GeoEditorState([switch]$Force) {
    if(-not $script:taskUi.GeoEditorStatus){return}
    if(-not $Force -and $script:geoEditorAt -and ((Get-Date)-$script:geoEditorAt).TotalSeconds -lt 3){return}
    $script:geoEditorAt=Get-Date
    try{
        $s=Read-GeoSettings $script:taskRoot
        $manual=($script:taskUi.GeoManual.IsChecked -eq $true)
        $script:taskUi.GeoUS.IsEnabled=$manual -and -not $script:taskBusy
        $script:taskUi.GeoEU.IsEnabled=$manual -and -not $script:taskBusy
        $script:taskUi.GeoModeHelp.Text=if($manual){'1. Выберите или впишите адрес US для ChatGPT и адрес EU для Gemini и вложений.  2. Нажмите «Сохранить и подключить».  3. Подтвердите запрос Windows.'}else{'Программа сама подбирает доступные адреса и сохраняет их в профиле. Чтобы использовать эту пару в Windows, нажмите «Подключить выбранные адреса» и подтвердите запрос Windows.'}
        $script:taskUi.GeoApply.Content=if($manual){'Сохранить и подключить'}else{'Подключить выбранные адреса'}
        $availability=Get-GeoPairAvailability $script:taskUi.GeoUS.Text.Trim() $script:taskUi.GeoEU.Text.Trim() $script:geoReport
        $script:taskUi.GeoApply.IsEnabled=(-not $script:taskBusy -and $availability.Ready)
        $script:taskUi.GeoSave.IsEnabled=-not $script:taskBusy
        $dirty=$script:taskUi.GeoUS.Text.Trim() -ne $s.us -or $script:taskUi.GeoEU.Text.Trim() -ne $s.eu
        $applied=Get-GeoApplicationState $script:taskRoot
        $script:taskUi.GeoEditorStatus.Foreground=Get-TaskBrush $(if($applied -and -not $dirty){'#91F2D2'}else{'#F6C56B'})
        $script:taskUi.GeoEditorStatus.Text=if($script:taskBusy){'Применение выполняется. Дождитесь результата Windows.'}elseif($dirty){'● Адреса отредактированы, но ещё не сохранены и не подключены.'}elseif($applied){'● Эти адреса уже применены в Windows. Это подтверждает настройку hosts; доступность смотрите в мониторинге.'}else{'● Адреса сохранены в профиле, но в Windows сейчас используются другие настройки. Нажмите кнопку подключения ниже.'}
        if(-not $availability.Ready){$script:taskUi.GeoEditorStatus.Text='Профиль сейчас нельзя подключить: '+$availability.Reason+'. '+$script:taskUi.GeoEditorStatus.Text;$script:taskUi.GeoEditorStatus.Foreground=Get-TaskBrush '#FFAC9A'}
        if($script:geoNotice){$script:taskUi.GeoEditorStatus.Text=$script:geoNotice+' '+$script:taskUi.GeoEditorStatus.Text;$script:taskUi.GeoEditorStatus.Foreground=Get-TaskBrush '#F6C56B'}
        foreach($region in @('US','EU')){
            $ip=$script:taskUi[('Geo'+$region)].Text.Trim()
            $row=@($script:geoReport.rows|Where-Object {$_.Address -eq $ip -and $_.Region -eq $region}|Select-Object -First 1)
            $text=if(-not (Test-GeoAddress $ip)){'Введите корректный публичный IPv4'}elseif(-not $row.Count){'Этот адрес ещё не проверен'}else{$row[0].State+' · '+$row[0].Country+' · '+([datetime]$row[0].CheckedAt).ToString('HH:mm:ss')}
            $script:taskUi[('Geo'+$region+'Help')].Text=$text
        }
    }catch{$script:taskUi.GeoEditorStatus.Text='Не удалось определить применение: '+$_.Exception.Message}
}

. (Join-Path $PSScriptRoot 'GeoHide.ps1')
. (Join-Path $PSScriptRoot 'GeoHideHistory.ps1')
. (Join-Path $PSScriptRoot 'GeoProfileUI.ps1')
. (Join-Path $PSScriptRoot 'Home.ps1')
$script:geoRegionFilter='ALL';$script:geoDisplayRows=@()
$script:geoRun=$null;$script:geoAt=[datetime]::MinValue;$script:geoSourceAt=[datetime]::MinValue;$script:geoReport=$null;$script:geoStamp=''
function Start-GeoMonitor([switch]$Refresh) {
    if($script:geoRun -or $SmokeTest -or $RenderPreview){return}
    $path=Join-Path $script:taskRoot 'geohide-monitor.json'
    $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $script:taskRoot 'GeoHideWorker.ps1')+'"'),'-ResultPath',('"'+$path+'"'))
    if($Refresh){$args+='-RefreshSources';$script:geoSourceAt=Get-Date}
    $process=Start-Process -FilePath $script:taskShell -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:geoRun=[pscustomobject]@{Process=$process;Path=$path;At=(Get-Date)}
    $script:taskUi.GeoStatus.Text='Проверяю адреса напрямую через физический интерфейс…'
}
function Update-GeoRows($Report) {
    if($Report.running -and $script:geoReport){
        $keys=@($Report.rows|ForEach-Object {$_.Region+'-'+$_.Address})
        $Report.rows=@($Report.rows)+@($script:geoReport.rows|Where-Object {($_.Region+'-'+$_.Address) -notin $keys})
    }
    $script:geoReport=$Report
    Update-GeoHistory $Report
    $us=@($Report.rows|Where-Object {$_.Region -eq 'US' -and $_.EligibleUS})
    $eu=@($Report.rows|Where-Object {$_.Region -eq 'EU' -and $_.EligibleEU})
    $draftUS=$script:taskUi.GeoUS.Text;$draftEU=$script:taskUi.GeoEU.Text
    $script:taskUi.GeoUS.ItemsSource=@($Report.rows|Where-Object Region -eq 'US'|ForEach-Object Address)
    $script:taskUi.GeoEU.ItemsSource=@($Report.rows|Where-Object Region -eq 'EU'|ForEach-Object Address)
    $settings=Read-GeoSettings $script:taskRoot
    $script:taskUi.GeoUS.Text=$(if($draftUS){$draftUS}else{$settings.us});$script:taskUi.GeoEU.Text=$(if($draftEU){$draftEU}else{$settings.eu})
    $script:taskUi.GeoStatus.Text=('US готовы: '+$us.Count+' / '+@($Report.rows|Where-Object Region -eq 'US').Count+' · EU готовы: '+$eu.Count+' · '+$Report.interface+' · '+([datetime]$Report.at).ToString('HH:mm:ss')+$(if($Report.running){' · проверка продолжается'}else{' · авто: 2 мин'}))
    $script:taskUi.GeoSourceStatus.Text=(@($Report.sources|ForEach-Object{$_.region+': '+$_.checkedAt}) -join ' · ')
    if(@($Report.sourceErrors).Count){$script:taskUi.GeoSourceStatus.Text+=' · Ошибка обновления; сохранён прежний список: '+($Report.sourceErrors -join '; ')}
    if(-not $Report.running -and ((Get-Date)-[datetime]$Report.at).TotalMinutes -lt 5){Sync-GeoRegions $Report}
    Update-GeoProfileCards

}
function Poll-GeoMonitor {
    Update-GeoEditorState
    if($script:geoRun){
        try{
            if(Test-Path -LiteralPath $script:geoRun.Path){
                $stamp=[IO.File]::GetLastWriteTimeUtc($script:geoRun.Path).ToString('o')
                if($stamp -ne $script:geoStamp){$script:geoStamp=$stamp;Update-GeoRows (Get-Content -LiteralPath $script:geoRun.Path -Raw -Encoding UTF8|ConvertFrom-Json)}
            }
            if($script:geoRun.Process.HasExited){
                if($script:geoRun.Process.ExitCode -ne 0){$script:taskUi.GeoStatus.Text='Ошибка диагностики. Предыдущие результаты сохранены; это не означает отказ всех серверов.'}
                $script:geoRun.Process.Dispose();$script:geoRun=$null;$script:geoAt=Get-Date
            }elseif(((Get-Date)-$script:geoRun.At).TotalSeconds -gt 240){
                $script:geoRun.Process.Kill();$script:geoRun.Process.Dispose();$script:geoRun=$null;$script:geoAt=Get-Date
                $script:taskUi.GeoStatus.Text='Общий тайм-аут проверки; показаны последние результаты.'
            }
        }catch{$script:taskUi.GeoStatus.Text='Ожидаю результат: '+$_.Exception.Message}
    }elseif(((Get-Date)-$script:geoAt).TotalSeconds -ge 120){Start-GeoMonitor -Refresh:(((Get-Date)-$script:geoSourceAt).TotalMinutes -ge 60)}
}
function Initialize-GeoMonitor {
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
    if(Test-Path -LiteralPath $path){try{Update-GeoRows (Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json)}catch{}}
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
        $script:taskUi.GeoModeHelp.Text=if($manual){'1. Выберите или впишите адрес US для ChatGPT и адрес EU для вложений.  2. Нажмите «Сохранить и подключить».  3. Подтвердите запрос Windows.'}else{'Программа сама подбирает доступные адреса и сохраняет их в профиле. Чтобы использовать эту пару в Windows, нажмите «Подключить выбранные адреса» и подтвердите запрос Windows.'}
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

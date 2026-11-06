function Get-GeoHomeState([string]$Root,$Report,[string]$HostsPath=(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')) {
    $text=Get-Content -LiteralPath $HostsPath -Raw -ErrorAction Stop
    $block=[regex]::Match($text,'(?ms)^# BEGIN CHATGPT-US-WINDOWS\r?\n(.*?)^# END CHATGPT-US-WINDOWS')
    if(-not $block.Success){
        if($text -match '# (BEGIN|END) CHATGPT-US-WINDOWS'){return [pscustomobject]@{On=$true;State='error';Title='Настройка повреждена';Detail='Откройте помощь для восстановления hosts.'}}
        return [pscustomobject]@{On=$false;State='off';Title='Выключено';Detail='Выберите маршрут в разделе «Серверы» и включите подключение.'}
    }
    $pendingGeminiUpdate=$false
    $catalogPath=Join-Path $Root 'profiles.json'
    $activeId=[regex]::Match($block.Groups[1].Value,'(?m)^# Profile ID:\s*(\S+)').Groups[1].Value
    if($activeId -and (Test-Path -LiteralPath $catalogPath)){
        $catalog=Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8|ConvertFrom-Json
        $entry=@($catalog.Profiles|Where-Object {$_.id -eq $activeId -and $_.service -eq 'GeoHide'})
        $pendingGeminiUpdate=$entry.Count -gt 0 -and -not (Get-GeoApplicationState $Root $HostsPath $activeId)
    }
    $needs=@{}
    foreach($line in ($block.Groups[1].Value -split '\r?\n')){
        $parts=($line -split '#',2)[0].Trim() -split '\s+'
        if($parts.Count -lt 2){continue}
        $row=@($Report.rows|Where-Object Address -eq $parts[0]|Select-Object -First 1)
        if(-not $row.Count){return [pscustomobject]@{On=$true;State='checking';Title='Включено · проверяю серверы';Detail='Адреса применены в Windows. Ожидаю актуальную сетевую проверку.'}}
        foreach($domain in $parts[1..($parts.Count-1)]){
            $gemini=Test-GeoGeminiDomain $domain
            $key=$row[0].Region+'|'+$parts[0]+'|'+$(if($gemini){'Gemini'}else{'ChatGPT'})
            if(-not $needs.ContainsKey($key)){$needs[$key]=[pscustomobject]@{Role=$row[0].Region;Address=$parts[0];Files=$false;Service=$(if($gemini){'Gemini'}else{'ChatGPT'})}}
            if($domain -eq 'oaiusercontent.com' -or $domain.EndsWith('.oaiusercontent.com')){$needs[$key].Files=$true}
        }
    }
    if(-not $needs.Count){return [pscustomobject]@{On=$true;State='error';Title='Настройка требует восстановления';Detail='Управляемый hosts пуст. Откройте «Помощь».'}}
    $result=Test-GeoRequirements @($needs.Values) $Report
    if($result.Ready -and $pendingGeminiUpdate){return [pscustomobject]@{On=$true;State='attention';Title='Включено · обновите профиль';Detail='Сохранённый профиль отличается от адресов в Windows. Откройте «Серверы», выберите нужный профиль и примените его кнопкой внизу. Доступность Gemini показана отдельно.'}}
    if($result.Ready -and $result.State -eq 'attention'){return [pscustomobject]@{On=$true;State='attention';Title='Подключено · Gemini ограничен';Detail=$result.Reason}}
    if($result.Ready){return [pscustomobject]@{On=$true;State='ready';Title='Включено';Detail='Серверы GeoHide отвечают. Подключение настроено.'}}
    if($Report.running -or $result.Reason -like '*устарела*'){return [pscustomobject]@{On=$true;State='checking';Title='Включено · проверяю серверы';Detail='Ожидаю завершения проверки текущего маршрута.'}}
    return [pscustomobject]@{On=$true;State='unavailable';Title='Сервер недоступен';Detail='Выбранный сервер не отвечает. Откройте «Серверы» и выберите доступный маршрут.'}
}
function Update-GeoHome([switch]$Force) {
    if(-not $script:taskUi.HomeToggle){return}
    if(-not $Force -and $script:homeAt -and ((Get-Date)-$script:homeAt).TotalSeconds -lt 3){return}
    $script:homeAt=Get-Date
    try{
        $script:homeState=Get-GeoHomeState $script:taskRoot $script:geoReport
        $id=$script:taskSelectedProfileId
        if(-not $id){$id=Get-GeoCombinedId $script:taskRoot}
        $profile=@($script:taskProfiles|Where-Object Id -eq $id|Select-Object -First 1)
        $availability=Get-GeoProfileAvailability $script:taskRoot $id $script:geoReport
        $script:taskUi.HomeRoute.Text=if($profile.Count){'Выбранный маршрут: '+$profile[0].Name}else{'Выберите маршрут в разделе «Серверы»'}
        $script:taskUi.HomeTitle.Text=$script:homeState.Title
        $script:taskUi.HomeDetail.Text=$script:homeState.Detail
        if(-not $script:homeState.On -and -not $availability.Ready){$script:taskUi.HomeDetail.Text='Для выбранного маршрута пока нет проверенных серверов. Выберите доступный маршрут в разделе «Серверы».'}
        $script:taskUi.HomeToggle.IsEnabled=(-not $script:taskBusy -and ($script:homeState.On -or $availability.Ready))
        $script:taskUi.HomeToggleCaption.Text=if($script:taskBusy){'Подождите…'}elseif($script:homeState.On){'Выключить'}else{'Включить'}
        $color=switch($script:homeState.State){ready{'#91F2D2'}checking{'#A4D5F2'}off{'#9CAEC4'}default{'#F6C56B'}}
        $script:taskUi.HomeTitle.Foreground=Get-TaskBrush $color
        $script:taskUi.HomeToggle.Foreground=Get-TaskBrush $color
        if($script:taskTray){$script:taskTray.Icon=if($script:homeState.State -in @('unavailable','error')){[Drawing.SystemIcons]::Warning}else{$script:taskTrayIcon};$script:taskTray.Text=('GeoRoute · '+$script:homeState.Title).Substring(0,[Math]::Min(63,('GeoRoute · '+$script:homeState.Title).Length));$script:taskTrayStatus.Text=$script:homeState.Title}
    }catch{$script:taskUi.HomeTitle.Text='Не удалось прочитать настройки';$script:taskUi.HomeDetail.Text=$_.Exception.Message}
}
function Invoke-GeoHomeToggle {
    if($script:taskBusy){return}
    $state=Get-GeoHomeState $script:taskRoot $script:geoReport
    if($state.On){Start-TaskAction 'Restore'}else{
        $id=$script:taskSelectedProfileId
        if(-not $id){$id=Get-GeoCombinedId $script:taskRoot}
        Start-TaskAction 'Apply' $id
    }
}

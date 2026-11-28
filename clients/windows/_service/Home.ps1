function Get-GeoHomeState([string]$Root,$Report,[string]$HostsPath=(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')) {
    $text=Get-Content -LiteralPath $HostsPath -Raw -ErrorAction Stop
    if(Get-Command Get-WarpHomeState -ErrorAction SilentlyContinue){$warpHome=Get-WarpHomeState $Root $text;if($warpHome){return $warpHome}}
    if ($text -match '(?m)^# Transport: GeoRouteWARP\s*$') {
        return [pscustomobject]@{On=$true; State='checking'; Title='WARP включён · нужна проверка'; Detail='Ответ выбранного сервера через WARP проверяется на главной.'}
    }
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
        $row = @($Report.rows | Where-Object { $_.Address -eq $parts[0] -and $_.Transport -ne 'Warp' } | Select-Object -First 1)
        if(-not $row.Count){return [pscustomobject]@{On=$true;State='checking';Title=$(if((Get-GeoMonitoringMinutes) -eq 0){'Включено · нужна ручная проверка'}else{'Включено · проверяю серверы'});Detail=$(if((Get-GeoMonitoringMinutes) -eq 0){'Автопроверка выключена. Нажмите «Проверить серверы» в мониторинге.'}else{'Адреса применены в Windows. Ожидаю актуальную сетевую проверку.'})}}
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
    if($result.Ready){return [pscustomobject]@{On=$true;State='ready';Title='Подключено напрямую';Detail='Профиль применён. По последней проверке сервер отвечает по HTTPS.'}}
    if($Report.running -or $result.Reason -like '*устарела*'){return [pscustomobject]@{On=$true;State='checking';Title=$(if(-not $Report.running -and (Get-GeoMonitoringMinutes) -eq 0){'Включено · нужна ручная проверка'}else{'Включено · проверяю серверы'});Detail=$(if(-not $Report.running -and (Get-GeoMonitoringMinutes) -eq 0){'Автопроверка выключена. Нажмите «Проверить серверы» в мониторинге.'}else{'Ожидаю завершения проверки текущего маршрута.'})}}
    return [pscustomobject]@{On=$true;State='unavailable';Title='Сервер недоступен';Detail='Выбранный сервер не отвечает. Откройте «Серверы» и выберите доступный маршрут.'}
}
# One visible primary action, and at most one alternative. The action ids also drive the click handlers.
function Get-GeoHomeView($State, [string]$Phase, [string]$Note) {
    $permission = ''
    $tone = 'normal'
    $label = 'ПОДКЛЮЧЕНИЕ'
    $primary = 'Direct'
    $secondary = ''
    switch ($Phase) {
        CheckDirect {
            $title = 'Проверяем сервер напрямую…'
            $detail = 'Проверяем HTTPS выбранного профиля. Настройки Windows пока не меняются.'
            $primary = ''
            $secondary = 'CancelCheck'
        }
        Apply {
            $title = 'Сервер ответил'
            $detail = 'Применяем профиль. Если Windows запросит разрешение, подтвердите его, чтобы подключиться.'
            $primary = ''
        }
        Offer {
            $label = 'ПРЯМАЯ ПРОВЕРКА'
            $tone = 'attention'
            $title = 'Сервер не ответил'
            $detail = 'Интернет доступен. Попробовать тот же сервер через туннель Cloudflare WARP? Если не хотите менять подключение, повторите проверку напрямую.'
            $primary = 'TryWarp'
            $secondary = 'Retry'
        }
        { $_ -in @('Consent','InstallOnly') } {
            $label = 'НЕОБЯЗАТЕЛЬНЫЙ КОМПОНЕНТ'
            $title = 'Установить WARP?'
            $detail = 'GeoRoute скачает WARP и добавит службу Windows. Туннель Cloudflare будет использоваться для адресов серверов GeoHide, в том числе из мониторинга. Остальной интернет работает как раньше.'
            $permission = 'Windows запросит права администратора. Служба останется после удаления portable-папки. Удалить её можно в «Дополнительно». Автоподключение выключено по умолчанию.'
            $primary = 'Install'
            $secondary = 'Cancel'
        }
        { $_ -in @('Installing','InstallOnlyBusy') } {
            $title = 'Устанавливаем компонент…'
            $detail = 'Дождитесь загрузки. Когда откроется запрос Windows, подтвердите установку или отмените её.'
            $primary = ''
        }
        ConnectWarp {
            $title = 'Включаем WARP…'
            $detail = 'После запуска туннеля ещё раз проверим выбранный сервер.'
            $primary = ''
        }
        CheckWarp {
            $label = 'ТУННЕЛЬ ВКЛЮЧЁН'
            $title = 'Проверяем сервер через WARP…'
            $detail = 'Туннель уже включён. Ждём ответа сервера, который проверяли напрямую.'
            $primary = ''
            $secondary = 'CancelCheck'
        }
        { $_ -in @('DirectReady','WarpReady') } {
            $tone = 'ready'
            $label = 'СЕРВЕР ОТВЕТИЛ'
            $title = if ($Phase -eq 'WarpReady') { 'Подключено через WARP' } else { 'Подключено напрямую' }
            $detail = 'Профиль применён, HTTPS проверен. Теперь откройте нужный сервис; вход и ответ модели проверяются в самом сервисе.'
            $primary = 'Disconnect'
        }
        CheckInternet {
            $tone = 'attention'
            $title = 'Проверьте интернет'
            $primary = 'Retry'
            $detail = 'Не удалось подтвердить доступ в интернет. Проверьте Wi-Fi или кабель и повторите прямую проверку.'
        }
        Denied {
            $tone = 'attention'
            $title = 'Сервис ограничил доступ'
            $primary = 'Retry'
            $secondary = 'Help'
            $detail = 'Сервис запросил проверку или отказал в доступе. Откройте его в браузере. GeoRoute не менял маршрут и не включал WARP.'
        }
        WarpFailed {
            $tone = 'attention'
            $title = 'Подключение через WARP не подтверждено'
            $primary = 'BackDirect'
            $secondary = 'Settings'
            $detail = if ($Note) { $Note } else { 'Туннель или выбранный сервер не прошёл проверку. Вернитесь к прямому подключению либо откройте журнал WARP.' }
        }
        ReturnDirect {
            $title = 'Возвращаемся к прямому подключению…'
            $detail = 'Сначала отключим WARP, затем проверим тот же профиль напрямую.'
            $primary = ''
        }
        Disconnecting {
            $title = 'Отключаемся…'
            $detail = 'Дождитесь подтверждения от Windows.'
            $primary = ''
        }
        Changed {
            $tone = 'attention'
            $title = 'Выбранный профиль изменился'
            $detail = 'Предыдущая проверка больше не подходит. Проверьте название профиля и начните заново.'
        }
        Expired {
            $title = 'Пора проверить сервер снова'
            $detail = 'После прямой проверки прошло больше пяти минут. Возможно, WARP уже не нужен.'
            $primary = 'Retry'
        }
        InstallFailed {
            $tone = 'attention'
            $title = 'Установка не подтверждена'
            $primary = 'Direct'
            $secondary = 'Settings'
            $detail = 'GeoRoute не запускал подключение через WARP. Можно продолжить напрямую или посмотреть состояние компонента.'
        }
        Installed {
            $title = 'Компонент установлен'
            $detail = 'Установка сама по себе не включает WARP. Новое подключение начнётся напрямую.'
        }
        OtherOwner {
            $tone = 'attention'
            $title = 'Компонент недоступен'
            $primary = 'Settings'
            $detail = 'Управлять этим WARP из текущей учётной записи нельзя. GeoRoute не переустанавливал службу и не менял маршрут.'
        }
        Conflict {
            $tone = 'attention'
            $title = 'Сначала отключите активный WARP'
            $primary = 'Settings'
            $detail = 'GeoRoute не будет проверять туннель как прямое подключение или менять другой активный маршрут.'
        }
        ActiveMismatch {
            $tone = 'attention'
            $title = 'Включён другой профиль'
            $detail = 'Активные настройки отличаются от выбранных. Ничего не переключено. Чтобы начать новое подключение, сначала отключите действующее.'
            $primary = 'Disconnect'
            $secondary = 'Servers'
        }
        Manual {
            $title = 'Выберите профиль'
            $primary = 'Servers'
            $detail = 'Для автоматической проверки нужен профиль GeoHide. Свой профиль можно применить вручную в разделе «Серверы».'
        }
        Failed {
            $tone = 'attention'
            $title = 'Подключение не подтверждено'
            $primary = 'Retry'
            $secondary = 'Help'
            $detail = if ($Note) { $Note } else { 'Не удалось подтвердить ответ выбранного сервера. Проверьте интернет и повторите попытку. Подробности — в журнале.' }
        }
        default {
            if ($State.On) {
                $title = $State.Title
                $detail = $State.Detail
                $primary = 'Disconnect'
                if ($State.Transport -eq 'Warp' -and $State.CanCheck) {
                    $primary = 'VerifyWarp'
                    $secondary = 'Disconnect'
                }
                if ($State.State -eq 'ready') { $tone = 'ready' }
                elseif ($State.State -ne 'checking') { $tone = 'attention' }
                if ($State.State -eq 'error' -and $State.Transport -ne 'Warp') {
                    $primary = 'Help'
                    $secondary = 'Disconnect'
                }
                if ($State.Transport -eq 'Warp' -and -not $State.CanControl) {
                    $primary = 'Settings'
                    $secondary = ''
                }
                if ($State.Transport -ne 'Warp' -and $State.State -in @('checking','unavailable')) {
                    $primary = 'CheckActive'
                    $secondary = 'Disconnect'
                    $detail = 'Профиль применён в Windows, но ответа сервера пока нет. Проверьте его ещё раз или отключитесь.'
                }
            } else {
                $label = 'НАПРЯМУЮ · БЕЗ WARP'
                $title = 'Готово к подключению'
                $detail = 'Сначала проверим выбранный сервер напрямую. Если он ответит, WARP не понадобится.'
                $permission = 'Чтобы применить профиль, Windows может запросить права администратора.'
            }
        }
    }
    [pscustomobject]@{
        Label = $label
        Title = $title
        Detail = $detail
        Permission = $permission
        Tone = $tone
        Primary = $primary
        Secondary = $secondary
    }
}

function Set-GeoHomeButton($Button, [string]$Action, [string]$Phase) {
    $captions = @{
        Direct = 'Подключиться'
        Retry = 'Повторить напрямую'
        TryWarp = 'Попробовать через WARP'
        Install = 'Установить и попробовать'
        Cancel = 'Не сейчас'
        CancelCheck = 'Отменить проверку'
        VerifyWarp = 'Проверить сервер'
        Disconnect = 'Отключиться'
        BackDirect = 'Вернуться к прямому подключению'
        Help = 'Помощь'
        Settings = 'Дополнительно'
        Servers = 'Выбрать профиль'
        CheckActive = 'Проверить напрямую'
    }
    $Button.Tag = $Action
    $Button.Visibility = if ($Action) { 'Visible' } else { 'Collapsed' }
    if (-not $Action) { return }
    $caption = if ($Action -eq 'Install' -and $Phase -eq 'InstallOnly') { 'Установить компонент' } else { $captions[$Action] }
    $Button.Content = $caption
    [Windows.Automation.AutomationProperties]::SetName($Button, $caption)
    $Button.IsEnabled = -not $script:taskBusy -or $Action -eq 'CancelCheck'
}

function Update-GeoHome([switch]$Force) {
    if (-not $script:taskUi.HomeToggle) { return }
    if (-not $Force -and $script:homeAt -and ((Get-Date) - $script:homeAt).TotalSeconds -lt 3) { return }
    $script:homeAt = Get-Date
    try {
        $state = Get-GeoHomeState $script:taskRoot $script:geoReport
        $script:homeState = $state
        Update-DnsSitesSummary
        $profile = Get-GeoHomeProfile
        $phase = $script:homePhase
        if ($phase -in @('DirectReady','WarpReady')) {
            $transport = if ($phase -eq 'WarpReady') { 'Warp' } else { 'Physical' }
            if (-not $state.On -or -not (Test-GeoHomeApplied $script:homeTarget $transport) -or
                ((Get-Date) - $script:homePhaseAt).TotalMinutes -gt 5 -or
                ($transport -eq 'Warp' -and (-not $state.CanCheck -or $state.CommandId -cne $script:homeWarpCommand))) {
                $script:homePhase = $phase = ''
            }
        }
        if ($phase -in @('Offer','Consent') -and -not (Test-GeoHomeTarget)) { $script:homePhase = $phase = 'Changed' }
        $view = Get-GeoHomeView $state $phase $script:homeNote
        $ui = $script:taskUi
        $ui.HomeLabel.Text = $view.Label
        $ui.HomeTitle.Text = $view.Title
        $ui.HomeDetail.Text = $view.Detail
        $ui.HomePermissionText.Text = $view.Permission
        $ui.HomePermissionText.Visibility = if ($view.Permission) { 'Visible' } else { 'Collapsed' }
        $ui.HomeRouteCaption.Text = if ($state.On -and -not $phase) { 'Действующий профиль' } else { 'Выбранный профиль' }
        $ui.HomeRoute.Text = if ($state.On -and -not $phase) {
            if ($state.ProfileName) { $state.ProfileName } elseif ($script:taskActiveProfileId) { ($script:taskProfiles | Where-Object Id -eq $script:taskActiveProfileId | Select-Object -First 1).Name } else { 'Профиль в Windows' }
        } elseif ($phase -and $script:homeTarget -and $phase -notin @('Changed','InstallOnly','InstallOnlyBusy','Installed')) { $script:homeTarget.Name }
          elseif ($profile) { $profile.Name } else { 'Профиль не выбран' }
        $ui.HomeServersButton.IsEnabled = -not $script:taskBusy
        Set-GeoHomeButton $ui.HomeToggle $view.Primary $phase
        Set-GeoHomeButton $ui.HomeSecondary $view.Secondary $phase
        $color = switch ($view.Tone) { ready { '#91F2D2' } attention { '#F6C56B' } default { '#B7D6EF' } }
        $ui.HomeLabel.Foreground = Get-TaskBrush $color
        $ui.HomeIndicator.Fill = $ui.HomeLabel.Foreground
        if ($script:taskTray) {
            $trayTitle = if ($script:dnsCurrentState.Active -and -not $state.On -and -not $phase) { 'DNS выбранных сайтов включён' } else { $view.Title }
            $script:taskTray.Icon = if ($view.Tone -eq 'attention') { [Drawing.SystemIcons]::Warning } else { $script:taskTrayIcon }
            $trayText = 'GeoRoute · ' + $trayTitle
            $script:taskTray.Text = $trayText.Substring(0, [Math]::Min(63, $trayText.Length))
            $script:taskTrayStatus.Text = $trayTitle
        }
    } catch {
        $script:taskUi.HomeTitle.Text = 'Не удалось прочитать настройки'
        $script:taskUi.HomeDetail.Text = 'Откройте помощь, прежде чем менять подключение.'
        Set-GeoHomeButton $script:taskUi.HomeToggle Help ''
        Set-GeoHomeButton $script:taskUi.HomeSecondary '' ''
    }
}

function Invoke-GeoHomeToggle {
    Invoke-GeoHomeAction ([string]$script:taskUi.HomeToggle.Tag)
}
